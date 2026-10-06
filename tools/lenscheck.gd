extends Node

# Independent static-observer shadow geometry and rendered scale invariance.
const Catch = preload("res://tools/coursecheck.gd").Catch
var logger := Catch.new()
var failures := 0
var checks := 0
var lens: LensPass
signal pixels_ready(images: Array)

func check(label: String, ok: bool) -> void:
	checks += 1
	if not ok: failures += 1
	print("%s %s" % ["ok" if ok else "FAIL", label])

func read_pixels() -> void:
	var dev := RDU.rd()
	var images := []
	for texture in [lens._march0, lens._march1]:
		images.append(Image.create_from_data(512, 512, false, Image.FORMAT_RGBAH, dev.texture_get_data(texture, 0)))
	call_deferred("publish_pixels", images)

func publish_pixels(images: Array) -> void:
	pixels_ready.emit(images)

func shadow_radius(img: Image) -> float:
	for x in range(256, 512):
		if img.get_pixel(x, 256).a >= 0.5: return float(x - 256)
	return INF

func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("LENSCHECK requires a graphical RenderingDevice")
		get_tree().quit(1)
		return
	OS.add_logger(logger)
	get_tree().create_timer(60.0).timeout.connect(func(): get_tree().quit(1))
	lens = LensPass.new()
	lens.set_size(512, 512)
	lens.set_scale(1.0)
	await RenderingServer.frame_post_draw
	var radii := {}
	var fov := deg_to_rad(60.0)
	for fixture in [[7.0, 1.0], [7.0, 1e-7], [20.0, 1.0], [20.0, 1e-7]]:
		var observer: float = fixture[0]
		var rs: float = fixture[1]
		# sin(alpha) = (sqrt(27)/2) * sqrt(1 - rs/R) * rs/R.
		var sine := sqrt(27.0) * 0.5 * sqrt(1.0 - 1.0 / observer) / observer
		var expected := (sine / sqrt(1.0 - sine * sine)) * 256.0 / tan(fov * 0.5)
		lens.dispatch({"holes": [{"pos": Vector3(0, 0, -observer * rs), "rs": rs}],
			"basis": Basis.IDENTITY, "fov": fov, "aspect": 1.0, "time": 0.0,
			"disc_intensity": 0.0, "disc_temp": 0.5, "disc_tpeak_phys": 1e7, "disc_outer": 3.0})
		await RenderingServer.frame_post_draw
		RenderingServer.call_on_render_thread(read_pixels)
		var images: Array = await pixels_ready
		var radius := shadow_radius(images[0])
		var prior: float = radii.get(observer, radius)
		radii[observer] = radius
		check("horizon %s observer %s analytic shadow" % [rs, observer], absf(radius - expected) <= 1.5)
		check("horizon %s captured center / escaping edge" % rs,
			images[0].get_pixel(256, 256).a == 0.0 and images[0].get_pixel(511, 256).a == 1.0)
		check("horizon %s finite fields" % rs, images.all(func(img: Image):
			for y in img.get_height():
				for x in img.get_width():
					var c := img.get_pixel(x, y)
					if not is_finite(c.r) or not is_finite(c.g) or not is_finite(c.b) or not is_finite(c.a): return false
			return true))
		check("observer %s shadow scale invariance" % observer, absf(prior - radius) <= 1.0)
		print("LENSCHECK SHADOW rs=%s observer=%s measured_px=%s expected_px=%s" % [rs, observer, radius, expected])
	for rs in [1.0, 1e-7]:
		var distance: float = 1e8 * rs
		var weak_fov := 0.01
		lens.dispatch({"holes": [{"pos": Vector3(0, 0, -distance), "rs": rs}],
			"basis": Basis.IDENTITY, "fov": weak_fov, "aspect": 1.0, "time": 0.0,
			"disc_intensity": 0.0, "disc_temp": 0.5, "disc_tpeak_phys": 1e7, "disc_outer": 3.0})
		await RenderingServer.frame_post_draw
		RenderingServer.call_on_render_thread(read_pixels)
		var images: Array = await pixels_ready
		var ray := Vector3((384.5 / 256.0 - 1.0) * tan(weak_fov * 0.5), (1.0 - 256.5 / 256.0) * tan(weak_fov * 0.5), -1.0).normalized()
		var impact: float = distance * Vector2(ray.x, ray.y).length()
		# First-order bend from a finite observer to infinity; rs/impact < 4e-6.
		var expected: float = (rs / impact) * (1.0 + sqrt(1.0 - pow(impact / distance, 2.0)))
		var delta: Color = images[1].get_pixel(384, 256)
		var measured := Vector3(delta.r, delta.g, delta.b).length()
		check("horizon %s far weak-field bend" % rs, is_finite(measured) and absf(measured - expected) <= expected * 0.05)
		check("horizon %s far ray escapes" % rs, images[0].get_pixel(384, 256).a == 1.0)
		print("LENSCHECK WEAK rs=%s measured_rad=%s expected_rad=%s" % [rs, measured, expected])
	lens.release()
	await RenderingServer.frame_post_draw
	var errors := logger.take()
	if not errors.is_empty(): failures += errors.size()
	for error in errors: printerr("LENSCHECK ENGINE ", error)
	OS.remove_logger(logger)
	print("LENSCHECK DONE checks=%d failures=%d" % [checks, failures])
	get_tree().quit(1 if failures else 0)
