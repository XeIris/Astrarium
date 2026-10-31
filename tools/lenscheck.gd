extends Node

# Independent static-observer shadow geometry, rendered scale invariance, and the
# Kerr shadow against Bardeen's (1973) spherical-photon-orbit boundary.
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

## Distance (px) from the centre to the shadow's edge along a pixel direction.
func shadow_edge(img: Image, dx: int, dy: int) -> float:
	for i in range(0, 256):
		if img.get_pixel(256 + dx * i + mini(dx, 0), 256 + dy * i + mini(dy, 0)).a >= 0.5: return float(i)
	return INF

# outer = 0 leaves no disc: with spin, the ISCO falls inside 3 r_s.
func march(holes: Array, basis: Basis, fov: float, intensity := 0.0, outer := 0.0) -> Array:
	lens.dispatch({"holes": holes, "basis": basis, "fov": fov, "aspect": 1.0, "time": 0.0,
		"disc_intensity": intensity, "disc_temp": 0.5, "disc_tpeak_phys": 1e7, "disc_outer": outer})
	await RenderingServer.frame_post_draw
	RenderingServer.call_on_render_thread(read_pixels)
	return await pixels_ready

# Bardeen's critical impact parameters, units of M: ξ = L/E and η = Q/E² (Q, Carter's
# constant) of the spherical photon orbit at r.
static func bardeen_xi(r: float, a: float) -> float:
	return -(r * r * r - 3.0 * r * r + a * a * r + a * a) / (a * (r - 1.0))
static func bardeen_eta(r: float, a: float) -> float:
	return r * r * r * (4.0 * a * a - r * pow(r - 3.0, 2.0)) / (a * a * pow(r - 1.0, 2.0))

func luminance_sum(img: Image, x0: int, x1: int) -> float:
	var s := 0.0
	for y in img.get_height():
		for x in range(x0, x1):
			var c := img.get_pixel(x, y)
			s += 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
	return s

## First pixel right of centre brighter than 1% of the row's peak.
func inner_emission(img: Image) -> float:
	var lum := func(c: Color) -> float: return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
	var peak := 0.0
	for x in range(256, 512): peak = maxf(peak, lum.call(img.get_pixel(x, 256)))
	for i in range(0, 256):
		if lum.call(img.get_pixel(256 + i, 256)) > 0.01 * peak and peak > 0.0: return float(i)
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
	await kerr_checks()
	lens.release()
	await RenderingServer.frame_post_draw
	var errors := logger.take()
	if not errors.is_empty(): failures += errors.size()
	for error in errors: printerr("LENSCHECK ENGINE ", error)
	OS.remove_logger(logger)
	print("LENSCHECK DONE checks=%d failures=%d" % [checks, failures])
	get_tree().quit(1 if failures else 0)

func kerr_checks() -> void:
	# A distant static observer in the disc plane (M = 0.5 scene units, R = 4000 M):
	# the edges at β = 0 are the equatorial photon orbits (η = 0), and α = 0 meets the
	# orbit with ξ = 0. The flattened, prograde edge is on the approaching (+x) side.
	var R := 4000.0
	var half := 9.0 / R
	var fov := 2.0 * atan(half)
	var px := 256.0 / half / R
	for a in [0.9, 0.998]:
		var images: Array = await march([{"pos": Vector3(0, 0, -R * 0.5), "rs": 1.0, "spin": a}], Basis.IDENTITY, fov)
		var r_pro := 2.0 * (1.0 + cos(2.0 / 3.0 * acos(-a)))
		var r_ret := 2.0 * (1.0 + cos(2.0 / 3.0 * acos(a)))
		var lo := r_pro
		var hi := r_ret
		for i in 60:
			var mid := 0.5 * (lo + hi)
			if bardeen_xi(lo, a) * bardeen_xi(mid, a) <= 0.0: hi = mid
			else: lo = mid
		var beta := sqrt(bardeen_eta(0.5 * (lo + hi), a))
		var right := shadow_edge(images[0], 1, 0)
		var left := shadow_edge(images[0], -1, 0)
		var up := shadow_edge(images[0], 0, -1)
		var down := shadow_edge(images[0], 0, 1)
		print("LENSCHECK KERR a=%s right_px=%s (%s) left_px=%s (%s) up_px=%s down_px=%s (%s)" % [
			a, right, bardeen_xi(r_pro, a) * px, left, -bardeen_xi(r_ret, a) * px, up, down, beta * px])
		check("a=%s prograde edge (Bardeen)" % a, absf(right - bardeen_xi(r_pro, a) * px) <= 1.5)
		check("a=%s retrograde edge (Bardeen)" % a, absf(left + bardeen_xi(r_ret, a) * px) <= 1.5)
		check("a=%s vertical extent (Carter constant)" % a, absf(up - beta * px) <= 1.5 and absf(down - beta * px) <= 1.5)
		# Pole-on, the shadow is a circle of radius √(η + a²) at the ξ = 0 orbit.
		var pole := Basis(Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(0, 1, 0))
		images = await march([{"pos": Vector3(0, -R * 0.5, 0), "rs": 1.0, "spin": a}], pole, fov)
		var expect := sqrt(beta * beta + a * a) * px
		var edges := [shadow_edge(images[0], 1, 0), shadow_edge(images[0], -1, 0), shadow_edge(images[0], 0, 1), shadow_edge(images[0], 0, -1)]
		print("LENSCHECK KERR POLE a=%s edges_px=%s expected_px=%s" % [a, edges, expect])
		check("a=%s pole-on circular shadow" % a, edges.all(func(e): return absf(e - expect) <= 1.5))
	# The disc: the approaching limb is brighter, and spin moves the inner edge in.
	var side := Basis.from_euler(Vector3(deg_to_rad(-12.0), 0, 0))
	var cam := side * Vector3(0, 0, 30.0)
	var disc: Array = await march([{"pos": -cam, "rs": 1.0, "spin": 0.9}], side, deg_to_rad(40.0), 1.0, 8.0)
	var lr := luminance_sum(disc[0], 0, 256)
	var rr := luminance_sum(disc[0], 256, 512)
	print("LENSCHECK DISC receding=%s approaching=%s" % [lr, rr])
	check("disc Doppler: approaching (+x) limb brighter", rr > 2.0 * lr and lr > 0.0)
	# Pole-on from afar, a* = 0.9 puts the ISCO (2.32 M) inside the photon region, so the
	# disc is seen in front of the shadow; at a* = 0 (6 M) its inner edge stays outside it.
	var top := Basis(Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(0, 1, 0))
	for a in [0.0, 0.9]:
		var bare: Array = await march([{"pos": Vector3(0, -R * 0.5, 0), "rs": 1.0, "spin": a}], top, fov)
		var lit: Array = await march([{"pos": Vector3(0, -R * 0.5, 0), "rs": 1.0, "spin": a}], top, fov, 1.0, 4.0)
		var shadow := shadow_edge(bare[0], 1, 0)
		var inner := inner_emission(lit[0])
		print("LENSCHECK DISC a=%s inner_px=%s shadow_px=%s" % [a, inner, shadow])
		check("a=%s disc inner edge %s the shadow" % [a, "inside" if a > 0.0 else "outside"],
			(inner < shadow - 3.0) if a > 0.0 else (inner >= shadow))
		check("a=%s disc fields finite" % a, lit.all(func(im: Image):
			for y in range(0, 512, 4):
				for x in range(0, 512, 4):
					var c := im.get_pixel(x, y)
					if not (is_finite(c.r) and is_finite(c.g) and is_finite(c.b) and is_finite(c.a)): return false
			return true))
