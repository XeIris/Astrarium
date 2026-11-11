extends Node

# How the galactic scene draws, judged in the rendered frame (docs/physics/galaxies.md):
# the glow shader's face-on surface brightness against the same integral done on the
# CPU in double, and the hand-over between drawn stars and the glow, whose flux must
# match. Windowed, because it reads the GPU's frame and must see SHADER ERRORs.
#   Godot --path . --resolution 1280x720 res://tools/galaxylookcheck.tscn -- [dump=/abs/dir]

const Catch = preload("res://tools/coursecheck.gd").Catch

## Views of the solar neighbourhood averaged for the hand-over, each a fresh draw of
## the lattice; and the shell measured, so that the nearest star cannot dominate.
const HANDOVER_VIEWS := 48
const INNER := 0.005
const HANDOVER_TOL := 0.06
const PROFILE_TOL := 0.04
## Rows across the dust lane, as offsets from the frame's centre row: edge-on from
## outside, and from the Sun, where the lane sits ~210 px above the centre and in-plane
## steps are optically thick. Columns spread over ±EDGE_HALF_PX; the CPU marches
## EDGE_SAMPLES (an in-plane ray's asinh spacing is otherwise ~0.4 kpc).
const DUST_ROWS := {"edge": [-24, -8, -3, 0, 3, 8, 24], "sun": [-280, -240, -215, -205, -190, -160, -100, 0]}
const EDGE_COLUMNS := 48
const EDGE_HALF_PX := 320
const EDGE_SAMPLES := 3000
const EDGE_EXPOSURE := 0.05
## From the Sun the glow's 28 steps cross ~30 kpc of arm dust in the plane: that
## quadrature reads 5.3 % bright in the lane against a converged CPU march (12000
## samples agree with 3000). A step attenuated at its midpoint reads 14 %.
const DUST_TOL := {"edge": 0.04, "sun": 0.08}
## The join: four views from the Sun at a night-sky exposure, each half of it (the drawn
## stars, the glow given up) against the CPU.
const JOIN_EXPOSURE := 1.0
const JOIN_TOL := 0.03
## A neighbour's glow against its CPU integral, at an exposure that keeps it unclipped.
const NEIGHBOUR_EXPOSURE := 0.05
## M104 seen 6° from edge-on through a 20 pc dust ring: as the Milky Way's lane from the Sun.
const TYPE_DUST_TOL := 0.08

var logger := Catch.new()
var stage: Node
var failures := 0
var checks := 0
var dump := ""

func check(label: String, ok: bool) -> void:
	checks += 1
	if not ok: failures += 1
	print("%s %s" % ["ok  " if ok else "FAIL", label])

func settle(frames := 4) -> void:
	for i in frames:
		stage.animate(1.0 / 60.0)
		await RenderingServer.frame_post_draw

## The scene's linear HDR frame, before the post chain.
func hdr() -> Image:
	await settle()
	return stage.pipe.scene_vp.get_texture().get_image()

func luma(c: Color) -> float:
	return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b

func mean_luma(img: Image) -> float:
	var s := 0.0
	var w := img.get_width()
	var h := img.get_height()
	for y in range(0, h, 2):
		for x in range(0, w, 2):
			s += luma(img.get_pixel(x, y))
	return s / float((w / 2) * (h / 2))

## Flux in the frame, in units of a centre pixel's solid angle: a star's drawn pixels
## sum to its flux wherever it falls (the point-source rule), but a pixel of glow is
## radiance, and a pixel at tan-plane (x, y) subtends (1 + x² + y²)^−3/2 of the centre's.
func frame_flux(img: Image, extended: bool) -> float:
	var w := img.get_width()
	var h := img.get_height()
	var t := tan(deg_to_rad(stage.cam_fov) * 0.5)
	var s := 0.0
	for y in range(0, h, 2):
		var ty := (1.0 - (float(y) + 0.5) / float(h) * 2.0) * t
		for x in range(0, w, 2):
			var tx := ((float(x) + 0.5) / float(w) * 2.0 - 1.0) * t * float(w) / float(h)
			var k := pow(1.0 + tx * tx + ty * ty, -1.5) if extended else 1.0
			s += luma(img.get_pixel(x, y)) * k
	return s * 4.0

func save(img: Image, tag: String) -> void:
	if dump.is_empty(): return
	var copy := img.duplicate()
	copy.convert(Image.FORMAT_RGBA8)
	copy.save_png(dump.path_join(tag + ".png"))

## Pin the exposure so frames compare: no adaptation, the user's exposure as given.
func pin(v: GalaxyVisual, exposure: float) -> void:
	v.exposure = exposure
	v.adaptation = 1.0
	stage.galaxy._adapted = true
	v.adapt_enabled = false

func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("GALAXYLOOKCHECK requires graphical rendering")
		get_tree().quit(1)
		return
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("dump=") and arg.trim_prefix("dump=").is_absolute_path():
			dump = arg.trim_prefix("dump=")
		else:
			printerr("GALAXYLOOKCHECK unknown option ", arg)
			get_tree().quit(1)
			return
	if not dump.is_empty() and DirAccess.make_dir_recursive_absolute(dump) != OK:
		printerr("GALAXYLOOKCHECK cannot create ", dump)
		get_tree().quit(1)
		return
	OS.add_logger(logger)
	get_tree().create_timer(600.0).timeout.connect(func():
		printerr("GALAXYLOOKCHECK timed out")
		get_tree().quit(1))
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	stage = load("res://main.tscn").instantiate()
	add_child(stage)
	await get_tree().process_frame
	stage.set_process(false)
	stage._start("sandbox")
	stage.lessons.store = ""
	stage.pipe.set_view_size(Vector2i(1280, 720))
	stage.load_preset("gal_milkyway")
	stage.galaxy.wait_tracers()
	stage.state.paused = true
	var v: GalaxyVisual = stage.galaxy.visual
	check("the scene is up with its tracers", stage.galaxy.active and v != null and stage.galaxy.tracers != null)
	if v != null:
		await views(v)
		await profile(v)
		await through_dust(v, "edge")
		await through_dust(v, "sun")
		await join(v)
		await landmarks()
		await neighbour_profile("m33")
		await neighbour_profile("lmc")
		await handover(v)
		# Last: it loads another scene, so nothing after it may hold the Milky Way's visual.
		await type_dust("gal_m104")
		await type_dust("gal_m51")
		await type_dust("gal_m87")
	for error in logger.take():
		failures += 1
		printerr("GALAXYLOOKCHECK ENGINE ", error)
	OS.remove_logger(logger)
	print("GALAXYLOOKCHECK DONE checks=%d failures=%d" % [checks, failures])
	get_tree().quit(1 if failures > 0 else 0)

# Every framing draws something, brighter at the galaxy than off it.
func views(v: GalaxyVisual) -> void:
	for f in ["whole", "face", "edge", "sun", "centre"]:
		stage.galaxy.frame(f)
		await settle(20)
		var img := await hdr()
		save(img, "view-" + f)
		var w := img.get_width()
		var h := img.get_height()
		var mid := luma(img.get_pixel(w / 2, h / 2))
		var all := mean_luma(img)
		var finite := is_finite(mid) and is_finite(all)
		check("%s: drawn, finite, centre %s over a mean %s" % [f, U.fixed(mid, 3), U.fixed(all, 4)], finite and all > 1e-4 and (f == "sun" or mid > all))

# Face-on, the glow's pixels against the CPU's integral along the same rays.
func profile(v: GalaxyVisual) -> void:
	stage.galaxy.frame("face")
	v.show_tracers = false
	v.show_stars = false
	pin(v, 0.05)
	var img := await hdr()
	save(img, "profile-face")
	# The background sky's own points are not the glow's.
	v.show_glow = false
	var sky := await hdr()
	v.show_glow = true
	var basis: Basis = stage.cam_basis
	var cam: Vector3 = stage.cam_pos.to_v3()
	var fov := deg_to_rad(stage.cam_fov)
	var size := Vector2(img.get_width(), img.get_height())
	var tan_h := tan(fov * 0.5)
	var gain := GalaxyVisual.K * SkyModel.star_gain() * v.exposure * v.adaptation
	var worst := 0.0
	var rings := 0
	# Rings of pixels about the centre: the jitter averages out over a ring.
	for rpx in [40, 80, 120, 160, 200, 240, 280]:
		var drawn := 0.0
		var want := 0.0
		var n := 64
		for k in n:
			var px := size * 0.5 + Vector2.from_angle(TAU * float(k) / float(n)) * float(rpx)
			var ndc := Vector2(px.x / size.x * 2.0 - 1.0, 1.0 - px.y / size.y * 2.0)
			var d := (basis * Vector3(ndc.x * tan_h * size.x / size.y, ndc.y * tan_h, -1.0)).normalized()
			drawn += luma(img.get_pixel(int(px.x), int(px.y))) - luma(sky.get_pixel(int(px.x), int(px.y)))
			want += v.ray_luminance(cam, d) * gain
		var err := absf(drawn / want - 1.0)
		print("     ring %d px: drawn %s, integral %s" % [rpx, U.expo(drawn / n, 3), U.expo(want / n, 3)])
		worst = maxf(worst, err)
		rings += 1
	check("face-on glow = CPU integral of the model's light in %d rings (worst %s %%, < %s)" % [rings, U.fixed(worst * 100.0, 1), U.fixed(PROFILE_TOL * 100.0, 0)], worst < PROFILE_TOL)
	v.show_tracers = true
	v.show_stars = true

# Through the dust lane: rows of pixels across it against the CPU's integral, so the
# glow's absorption (its in-step mean, and the spheroid reading the disc march's
# optical depth) is held where it is thick. Pixel centres exactly: the lane is a few
# pixels high edge-on.
func through_dust(v: GalaxyVisual, framing: String) -> void:
	stage.galaxy.frame(framing)
	v.show_tracers = false
	v.show_stars = false
	pin(v, EDGE_EXPOSURE)
	var img := await hdr()
	save(img, "dust-" + framing)
	v.show_glow = false
	var sky := await hdr()
	v.show_glow = true
	var basis: Basis = stage.cam_basis
	var cam: Vector3 = stage.cam_pos.to_v3()
	var size := Vector2(img.get_width(), img.get_height())
	var tan_h := tan(deg_to_rad(stage.cam_fov) * 0.5)
	var gain := GalaxyVisual.K * SkyModel.star_gain() * v.exposure * v.adaptation
	var worst := 0.0
	var rows := 0
	for dy in DUST_ROWS[framing]:
		var drawn := 0.0
		var want := 0.0
		for k in EDGE_COLUMNS:
			var ix := int(size.x * 0.5) + int((float(k) / float(EDGE_COLUMNS - 1) * 2.0 - 1.0) * EDGE_HALF_PX)
			var iy := int(size.y * 0.5) + int(dy)
			var ndc := Vector2((float(ix) + 0.5) / size.x * 2.0 - 1.0, 1.0 - (float(iy) + 0.5) / size.y * 2.0)
			var d := (basis * Vector3(ndc.x * tan_h * size.x / size.y, ndc.y * tan_h, -1.0)).normalized()
			drawn += luma(img.get_pixel(ix, iy)) - luma(sky.get_pixel(ix, iy))
			want += v.ray_luminance(cam, d, 1e-3, EDGE_SAMPLES) * gain
		var err := absf(drawn / want - 1.0)
		print("     row %+d px: drawn %s, integral %s" % [int(dy), U.expo(drawn / EDGE_COLUMNS, 3), U.expo(want / EDGE_COLUMNS, 3)])
		worst = maxf(worst, err)
		rows += 1
	check("%s: glow through the dust = CPU integral in %d rows (worst %s %%, < %s)" % [framing, rows, U.fixed(worst * 100.0, 1), U.fixed(DUST_TOL[framing] * 100.0, 0)], worst < DUST_TOL[framing])
	v.show_tracers = true
	v.show_stars = true

# From the Sun the real stars join the model: the far set's light drawn as stars equals
# what the glow gives up (both seen whole in four views), and inside the real stars'
# sphere the lattice draws nothing.
func join(v: GalaxyVisual) -> void:
	if not v.has_sun:
		check("the real stars around the Sun are loaded (assets/sky/neighbourhood.bin)", false)
		return
	stage.galaxy.frame("sun")
	v.show_tracers = false
	pin(v, JOIN_EXPOSURE)
	v.res_override = 0.0
	var nb: Dictionary = v.neighbourhood
	var worst_s := 0.0
	var worst_g := 0.0
	var given := 0.0
	for phi in [PI, 0.0, PI / 2.0, 3.0 * PI / 2.0]:
		stage.cam.phi = phi
		stage.cam.theta = PI / 2.0
		stage.update_orbit_cam()
		var a := await hdr()
		v.show_catalogue = false
		var b := await hdr()
		v.join_enabled = false
		var c := await hdr()
		v.join_enabled = true
		v.show_catalogue = true
		save(a, "join-%d" % int(rad_to_deg(phi)))
		var size := Vector2(a.get_width(), a.get_height())
		var basis: Basis = stage.cam_basis
		var tan_h := tan(deg_to_rad(stage.cam_fov) * 0.5)
		var aspect := size.x / size.y
		# The stars: every pixel, against each star projected with the point rule.
		var drawn := pixel_sum(a) - pixel_sum(b)
		var want := 0.0
		var cam_v: Vector3 = stage.cam_pos.to_v3()
		var sun_rel := v.sun_pos - cam_v
		for i in range(int(nb.n_near), int(nb.n_near) + int(nb.n_far)):
			var rel: Vector3 = sun_rel + v.sun_basis * (nb.pos[i] as Vector3)
			var q := basis.inverse() * rel
			if q.z >= 0.0: continue
			var x := q.x / -q.z / (tan_h * aspect)
			var y := q.y / -q.z / tan_h
			# Wholly inside: a 5 px quad's half-width in from the edges.
			if absf(x) > 1.0 - 6.0 / size.x or absf(y) > 1.0 - 6.0 / size.y: continue
			var f := GalNeighbourhood.l_vis(nb.mv[i]) / (4.0 * PI * rel.length_squared())
			var pf := point_flux(f / v.last_pix_sr * v.last_gain)
			if pf / BrightStars.PROFILE_PX2 >= 2e-4: want += pf
		# The glow: what it gave up against the map at the same pixels.
		var gave := frame_flux(c, true) - frame_flux(b, true)
		var expect := 0.0
		var t := tan(deg_to_rad(stage.cam_fov) * 0.5)
		for py in range(0, int(size.y), 2):
			var ty := (1.0 - (float(py) + 0.5) / size.y * 2.0) * t
			for px in range(0, int(size.x), 2):
				var tx := ((float(px) + 0.5) / size.x * 2.0 - 1.0) * t * aspect
				var d := (basis * Vector3(tx, ty, -1.0)).normalized()
				var k := pow(1.0 + tx * tx + ty * ty, -1.5)
				expect += map_luma(v, d) * v.last_gain * k
		expect *= 4.0
		var es := absf(drawn / want - 1.0)
		var eg := absf(gave / expect - 1.0)
		print("     toward φ = %d°: stars drawn %s, by the point rule %s; glow gave %s, the map %s; %s %% of the view's glow" % [
			int(rad_to_deg(phi)), U.expo(drawn, 3), U.expo(want, 3), U.expo(gave, 3), U.expo(expect, 3), U.fixed(100.0 * gave / frame_flux(c, true), 1)])
		worst_s = maxf(worst_s, es)
		worst_g = maxf(worst_g, eg)
		given += gave / frame_flux(c, true)
	check("from the Sun, the real stars are drawn as the point rule says (worst %s %% in 4 views, < %s)" % [U.fixed(worst_s * 100.0, 1), U.fixed(JOIN_TOL * 100.0, 0)], worst_s < JOIN_TOL)
	check("from the Sun, the glow gives up the real stars' light map (worst %s %%, < %s; %s %% of the glow)" % [
		U.fixed(worst_g * 100.0, 1), U.fixed(JOIN_TOL * 100.0, 0), U.fixed(given / 4.0 * 100.0, 1)], worst_g < JOIN_TOL and given > 0.05)
	# The camera's resolved sphere inside the real stars' one: no procedural star. The
	# background sky's own points are measured apart and taken off both.
	v.res_override = 0.035
	v.show_glow = false
	v.show_catalogue = false
	v.show_stars = false
	var bg := frame_flux(await hdr(), false)
	v.show_stars = true
	var himg := await hdr()
	save(himg, "join-hole")
	var holed := frame_flux(himg, false) - bg
	v.join_enabled = false
	var lattice := frame_flux(await hdr(), false) - bg
	v.join_enabled = true
	check("inside the real stars' sphere the lattice draws nothing (%s of its light without the join)" % U.expo(holed / maxf(lattice, 1e-30), 2),
		lattice > 0.0 and absf(holed) < 1e-3 * lattice)
	v.show_glow = true
	v.show_catalogue = true
	v.res_override = -1.0
	v.show_tracers = true

# Flying to each landmark: after two seconds the camera is there, its card is shown, and
# its own label is hidden up close.
func landmarks() -> void:
	var g = stage.galaxy
	var lms: Array = g.landmarks
	var bad := []
	for lm in lms:
		g.fly(String(lm.id))
		await settle(120)
		var p := GalLandmarks.position(lm, g.model, g.t_myr)
		var err := 0.0
		err = (stage.cam.target.to_v3() - p).length() / float(lm.view[0])
		var card: String = stage.hud.ids.galCard.said()
		var label: Control = g._lm_labels.get(lm.id)
		if err > 1e-3 or card != String(lm.card) or label == null or label.visible:
			bad.append("%s (off by %s of its view, card %s, label %s)" % [lm.id, U.expo(err, 1), "ok" if card == String(lm.card) else "wrong",
				"hidden" if label != null and not label.visible else "shown"])
	check("flying to each of %d landmarks arrives, shows its card and hides its own label%s" % [lms.size(), "" if bad.is_empty() else ": " + ", ".join(bad)],
		lms.size() > 0 and bad.is_empty())
	g.frame("whole")

# A neighbour drawn where it is and as it is tilted: its glow (its own alone, against the
# frame without it) against the CPU's integral along the same rays turned into its frame.
func neighbour_profile(key: String) -> void:
	var g = stage.galaxy
	var nb := {}
	for n in g.neighbours:
		if n.key == key: nb = n
	if nb.is_empty():
		check("%s is drawn" % key, false)
		return
	g.fly(key)
	await settle(120)
	var v: GalaxyVisual = nb.visual
	pin(g.visual, NEIGHBOUR_EXPOSURE)
	g.visual.show_tracers = false
	g.visual.show_stars = false
	var img := await hdr()
	save(img, "neighbour-" + key)
	nb.hide = true
	var without := await hdr()
	nb.hide = false
	var basis: Basis = stage.cam_basis
	var cam: Vector3 = stage.cam_pos.to_v3()
	var size := Vector2(img.get_width(), img.get_height())
	var tan_h := tan(deg_to_rad(stage.cam_fov) * 0.5)
	var nbb: Basis = nb.basis
	var o: Vector3 = nbb.inverse() * (cam - (nb.centre as DVec3).to_v3())
	var gain := GalaxyVisual.K * SkyModel.star_gain() * v.exposure * v.adaptation
	var worst := 0.0
	for rpx in [10, 30, 60, 100, 150]:
		var drawn := 0.0
		var want := 0.0
		for k in 48:
			var px := size * 0.5 + Vector2.from_angle(TAU * float(k) / 48.0) * float(rpx)
			var ix := int(px.x)
			var iy := int(px.y)
			var ndc := Vector2((float(ix) + 0.5) / size.x * 2.0 - 1.0, 1.0 - (float(iy) + 0.5) / size.y * 2.0)
			var d := (basis * Vector3(ndc.x * tan_h * size.x / size.y, ndc.y * tan_h, -1.0)).normalized()
			drawn += luma(img.get_pixel(ix, iy)) - luma(without.get_pixel(ix, iy))
			want += v.ray_luminance(o, nbb.inverse() * d, 1e-3, 1200) * gain
		var err := absf(drawn / want - 1.0)
		print("     %s ring %d px: drawn %s, integral %s" % [key, rpx, U.expo(drawn / 48.0, 3), U.expo(want / 48.0, 3)])
		worst = maxf(worst, err)
	check("%s drawn where it is and tilted as it is: its glow = the CPU integral in its frame (worst %s %%, < %s)" % [key, U.fixed(worst * 100.0, 1), U.fixed(PROFILE_TOL * 100.0, 0)], worst < PROFILE_TOL)
	g.visual.show_tracers = true
	g.visual.show_stars = true
	g.frame("whole")

# A galaxy of its own scene, in rows across its middle against the CPU's integral: M104
# through its 20 pc dust ring (the thin sampling), M51 across its arms (the arm map).
func type_dust(preset: String) -> void:
	stage.load_preset(preset)
	stage.galaxy.wait_tracers()
	stage.state.paused = true
	var g = stage.galaxy
	var v: GalaxyVisual = g.visual
	g.frame("whole")
	# The galaxy's glow alone: its companions and H II regions are not in the CPU's integral.
	for n in g.neighbours: n.hide = true
	v.show_hii = false
	await settle(20)
	pin(v, 0.3)
	var img := await hdr()
	save(img, "type-" + preset)
	v.show_glow = false
	var sky := await hdr()
	v.show_glow = true
	var basis: Basis = stage.cam_basis
	var cam: Vector3 = stage.cam_pos.to_v3()
	var size := Vector2(img.get_width(), img.get_height())
	var tan_h := tan(deg_to_rad(stage.cam_fov) * 0.5)
	var gain := GalaxyVisual.K * SkyModel.star_gain() * v.exposure * v.adaptation
	var worst := 0.0
	for dy in [-60, -20, -8, 0, 8, 20, 60]:
		var drawn := 0.0
		var want := 0.0
		for k in 48:
			var ix := int(size.x * 0.5) + int((float(k) / 47.0 * 2.0 - 1.0) * 220.0)
			var iy: int = int(size.y * 0.5) + int(dy)
			var ndc := Vector2((float(ix) + 0.5) / size.x * 2.0 - 1.0, 1.0 - (float(iy) + 0.5) / size.y * 2.0)
			var d := (basis * Vector3(ndc.x * tan_h * size.x / size.y, ndc.y * tan_h, -1.0)).normalized()
			drawn += luma(img.get_pixel(ix, iy)) - luma(sky.get_pixel(ix, iy))
			want += v.ray_luminance(cam, d, 1e-3, 4000) * gain
		print("     %s row %+d: drawn %s, integral %s" % [preset, dy, U.expo(drawn / 48.0, 3), U.expo(want / 48.0, 3)])
		worst = maxf(worst, absf(drawn / want - 1.0))
	check("%s: glow = CPU integral in 7 rows across it (worst %s %%, < %s)" % [preset, U.fixed(worst * 100.0, 1), U.fixed(TYPE_DUST_TOL * 100.0, 0)], worst < TYPE_DUST_TOL)
	v.show_hii = true
	if v.hii != null: await hii_flux(v, gain)
	for n in g.neighbours: n.hide = false
	stage.load_preset("gal_milkyway")
	stage.galaxy.wait_tracers()
	stage.state.paused = true

## The H II regions alone against the CPU: each drawn blob's pixels sum to its light, dimmed by
## the dust between it and the camera as the shader marches it, over 4π, the pixel's area and
## the gain.
const HII_TOL := 0.03
func hii_flux(v: GalaxyVisual, gain: float) -> void:
	v.show_glow = false
	v.hii_with_glow = false
	await settle(4)
	var img := await hdr()
	v.show_hii = false
	await settle(4)
	var sky := await hdr()
	v.show_hii = true
	v.show_glow = true
	v.hii_with_glow = true
	var drawn := pixel_sum(img) - pixel_sum(sky)
	var cam := v.glow_mat.get_shader_parameter("uCamLocal") as Vector3
	var pix := float(v.hii_mat.get_shader_parameter("uPix"))
	var e: Array = GalModels.EXTINCTION_RGB
	var want := 0.0
	var cat: Dictionary = v.hii_cat
	var zl := 8.0 * maxf(float(v.dust_map.z), 0.01)
	for i in cat.n:
		var p: Vector3 = cat.pos[i]
		var rel := p - cam
		var dist := rel.length()
		var dir := -rel / dist
		var t1 := dist
		if absf(dir.y) > 1e-6: t1 = minf(t1, maxf((signf(dir.y) * zl - p.y) / dir.y, 0.0))
		var tau := 0.0
		for k in 16:
			var q := p + dir * ((float(k) + 0.5) * t1 / 16.0)
			tau += v.dust_density(q.x, q.y, q.z) * t1 / 16.0
		var c: Color = (cat.stars[i] as Color) + (cat.lines[i] as Color)
		var att := Color(c.r * exp(-tau * float(e[0])), c.g * exp(-tau * float(e[1])), c.b * exp(-tau * float(e[2])))
		want += luma(att) * gain / (4.0 * PI * pix * pix * dist * dist)
	var err := absf(drawn / want - 1.0)
	check("%d H II regions: drawn %s, CPU %s (%s %%, < %s)" % [cat.n, U.expo(drawn, 4), U.expo(want, 4), U.fixed(err * 100.0, 2), U.fixed(HII_TOL * 100.0, 0)], err < HII_TOL)

## Luminance summed over every pixel: a point's drawn pixels sum to its flux.
func pixel_sum(img: Image) -> float:
	var s := 0.0
	for y in img.get_height():
		for x in img.get_width():
			s += luma(img.get_pixel(x, y))
	return s

## shaders/common/point_source.gdshaderinc's mapping, on the CPU.
static func point_flux(f: float) -> float:
	return f if f <= 1000.0 else 1000.0 * (1.0 + log(f / 1000.0))

## The far set's light map at a galaxy-local direction, bilinear as the GPU reads it.
func map_luma(v: GalaxyVisual, d: Vector3) -> float:
	var img: Image = v.neighbourhood.map
	var lb := GalNeighbourhood.galactic(v.sun_basis.inverse() * d)
	var fx := lb.x / TAU * GalNeighbourhood.MAP_W - 0.5
	var fy := clampf((0.5 - lb.y / PI) * GalNeighbourhood.MAP_H - 0.5, 0.0, GalNeighbourhood.MAP_H - 1.0)
	var x0 := int(floor(fx))
	var y0 := int(floor(fy))
	var wx := fx - float(x0)
	var wy := fy - float(y0)
	var y1 := mini(y0 + 1, GalNeighbourhood.MAP_H - 1)
	var c := img.get_pixel(posmod(x0, GalNeighbourhood.MAP_W), y0).lerp(img.get_pixel(posmod(x0 + 1, GalNeighbourhood.MAP_W), y0), wx).lerp(
		img.get_pixel(posmod(x0, GalNeighbourhood.MAP_W), y1).lerp(img.get_pixel(posmod(x0 + 1, GalNeighbourhood.MAP_W), y1), wx), wy)
	return luma(c)

# The stars drawn one by one carry the light the glow gives up to them. Every star is
# white with the mean luminosity of its population, so the light in the shell from
# INNER to the resolved radius is n·L either way; only the stars' Poisson draw differs.
func handover(v: GalaxyVisual) -> void:
	stage.galaxy.frame("sun")
	# The model against itself: no real stars, and the camera free to leave the Sun.
	stage.galaxy.follow_sun = false
	v.join_enabled = false
	v.show_tracers = false
	pin(v, 0.02)
	var white := Vector3(1, 1, 1)
	var keep_d: Vector3 = v.glow_mat.get_shader_parameter("uDiscCol")
	var keep_s: Vector3 = v.glow_mat.get_shader_parameter("uSphereCol")
	var keep_f: Vector2 = v.glow_mat.get_shader_parameter("uFaint")
	v.glow_mat.set_shader_parameter("uDiscCol", white)
	v.glow_mat.set_shader_parameter("uSphereCol", white)
	v.glow_mat.set_shader_parameter("uInner", INNER)
	v.star_mat.set_shader_parameter("uInner", INNER)
	v.star_mat.set_shader_parameter("uFixL", 1.0 / v.disc_pop.resolved_per_l)
	# The spheroid's stars would need their own L; at the Sun they are a few in a million.
	var sun := Vector3(-8.0, 0.02, 0.0)
	var share := GalaxyVisual.sphere_share(v, sun)
	check("spheroid's share of the stars at the Sun %s < 1e-3" % U.expo(share, 2), share < 1e-3)
	var stars := 0.0
	var glow := 0.0
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	for i in HANDOVER_VIEWS:
		stage.cam.phi = rng.randf() * TAU
		stage.cam.theta = rng.randf_range(0.6, PI - 0.6)
		stage.cam.target.set_v(-8.0 + rng.randf_range(-0.2, 0.2), 0.02, rng.randf_range(-0.2, 0.2))
		stage.update_orbit_cam()
		# a: stars + the glow beyond them; c: the glow beyond them alone; b: the glow throughout.
		v.glow_mat.set_shader_parameter("uFaint", Vector2(0.0, 0.0))
		v.show_stars = true
		var a := await hdr()
		v.show_stars = false
		v.res_override = GalaxyVisual.RES_MAX
		var c := await hdr()
		v.res_override = 0.0
		var b := await hdr()
		v.res_override = -1.0
		# a − c is the stars alone; b − c is the glow's shell alone.
		stars += frame_flux(a, false) - frame_flux(c, false)
		glow += frame_flux(b, true) - frame_flux(c, true)
	var ratio := stars / glow
	check("hand-over over %d views: stars carry %s of the glow's shell light (1 ± %s)" % [HANDOVER_VIEWS, U.fixed(ratio, 3), U.fixed(HANDOVER_TOL, 2)],
		glow > 0.0 and absf(ratio - 1.0) < HANDOVER_TOL)
	v.glow_mat.set_shader_parameter("uDiscCol", keep_d)
	v.glow_mat.set_shader_parameter("uSphereCol", keep_s)
	v.glow_mat.set_shader_parameter("uFaint", keep_f)
	v.glow_mat.set_shader_parameter("uInner", 0.0)
	v.star_mat.set_shader_parameter("uInner", 0.0)
	v.star_mat.set_shader_parameter("uFixL", 0.0)
	v.show_stars = true
	v.show_tracers = true
	v.join_enabled = true
