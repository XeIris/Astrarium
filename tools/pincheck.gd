extends Node

# The pin and the showcase. Headless: the draw, what it reads, the mode's manners. With gpu=1 it also
# renders the shader's height at random points and holds the CPU's crust to it, and judges the marker.
const Catch = preload("res://tools/coursecheck.gd").Catch
var catcher := Catch.new()
var stage: Node
var checks := 0
var failures := 0
var args := {}

func check(label: String, ok: bool) -> void:
	checks += 1
	if not ok: failures += 1
	print("%s %s" % ["ok" if ok else "FAIL", label])

func near(a: float, b: float, tol: float) -> bool:
	return absf(a - b) <= tol

func new_stage(preset: String) -> void:
	stage.load_preset(preset)
	stage.set_process(false)
	stage.state.paused = true

func spawn_world(mix: String, au: float, name_: String, extra := {}) -> Body:
	var inputs: Dictionary = Composition.MIXES[mix].inputs.duplicate()
	inputs.merge(extra, true)
	var spec := {"type": "planet", "mass": 3e-6, "name": name_, "seed": 4242, "obliquity": 0.41}
	spec.merge(inputs, true)
	# Exactly there: the Foundry's orbit keeps clear of a boosted star, which is a stage's choice.
	var lamp: Body = stage.get_stars()[0]
	var at := DVec3.new(cos(1.0), 0.0, sin(1.0)).scaled(au).add(lamp.pos)
	spec.pos = at.to_array()
	spec.vel = [0.0, 0.0, 0.0]
	var b: Body = stage.spawn_body(spec)
	for i in 3: stage.animate(1.0 / 60.0)
	# The look's first frame has snapped; the frame after has a live ice line too.
	return b

func draws() -> void:
	new_stage("solar")
	var earth: Body = stage.state.body_named("Earth")
	var a := PlanetPin.drop(earth, 1, 0)
	var b := PlanetPin.drop(earth, 1, 0)
	check("the same seed and number land in the same place", a.lat == b.lat and a.lon == b.lon)
	check("and read the same ground", a.ground.text == b.ground.text)
	check("the next pin lands elsewhere", PlanetPin.drop(earth, 2, 0).lat != a.lat)
	check("another run seed lands elsewhere", PlanetPin.drop(earth, 1, 9).lat != a.lat)
	# Equal area: a band's share of pins goes as its share of the sphere (sin lat is uniform).
	var mars: Body = stage.state.body_named("Mars")
	var n := 4000
	var tropics := 0
	var east := 0
	var key := str(U.nz(mars.spec.get("seed"), mars.name))
	for i in n:
		var at := PlanetPin.draw(key, 0, i)
		if absf(at.x) < deg_to_rad(23.44): tropics += 1
		if at.y > 0.0: east += 1
	check("the tropics take their share of the sphere, 39.8%% (%.1f%%)" % (100.0 * tropics / n), near(float(tropics) / n, 0.3978, 0.025))
	check("the hemispheres split evenly (%.1f%%)" % (100.0 * east / n), near(float(east) / n, 0.5, 0.025))

	# The direction helper against the map's frame: 0° N 0° E is the +X meridian's opposite of u = 0.
	var eq := PlanetPin.direction(0.0, 0.0)
	check("0° N, 0° E is the map's centre line", near(eq.x, 1.0, 1e-6))
	check("the pole is on the mesh's +Y", near(PlanetPin.direction(PI * 0.5, 0.3).y, 1.0, 1e-6))
	var uv_u := fposmod((0.0 + PI) / TAU, 1.0)
	check("and that is u = ½", near(uv_u, 0.5, 1e-9))
	# Earth's mask, with places whose answer is known.
	check("the Sahara is land", PlanetPin.land_at("Earth", deg_to_rad(23.0), deg_to_rad(10.0)))
	check("the Pacific is not", not PlanetPin.land_at("Earth", deg_to_rad(0.0), deg_to_rad(-150.0)))
	check("nor the Atlantic", not PlanetPin.land_at("Earth", deg_to_rad(30.0), deg_to_rad(-40.0)))
	check("Australia is", PlanetPin.land_at("Earth", deg_to_rad(-25.0), deg_to_rad(134.0)))
	# Over many pins, Earth's land share is its own.
	var land := 0
	var count := 0
	for i in range(1, 2001):
		var at := PlanetPin.draw("Earth", 0, i)
		if PlanetPin.land_at("Earth", at.x, at.y): land += 1
		count += 1
	check("pins fall on land about 29%% of the time on Earth (%.1f%%)" % (100.0 * land / count), near(float(land) / count, 0.29, 0.03))
	PlanetPin.release_maps()

func ground_reads() -> void:
	new_stage("solar")
	var star: Body = stage.state.body_named("Sun")
	# A world's kinds, at places chosen by asking its own crust.
	var w := spawn_world("earth", 1.0, "Wet", {"land": 0.4, "biota": 1.0})
	var r := PlanetRelief.of_visual(PlanetPin._viz(w))
	var saw := {}
	for i in range(1, 80):
		var pin := PlanetPin.drop(w, i, 0)
		saw[pin.ground.kind] = true
		var h := r.height(pin.p).x
		if pin.ground.kind == "sea": check("pin %d: sea is under the sea (%.1f km)" % [i, h], h < r.sea_km)
		if pin.ground.kind == "land": check("pin %d: land is above it (%.1f km)" % [i, h], h >= r.sea_km)
		check("pin %d says what it found" % i, not String(pin.ground.text).is_empty())
	check("an ocean world has sea and land both", saw.has("sea") and saw.has("land"))
	var dry := spawn_world("bare", 1.0, "Rock")
	var pin := PlanetPin.drop(dry, 1, 0)
	check("a rock's pin is land", pin.ground.kind == "land")
	check("and calls it bare (%s)" % pin.ground.text, String(pin.ground.biome).begins_with("bare"))
	var ball := spawn_world("ocean", 1.0, "Ball")
	var all_sea := true
	for i in range(1, 30):
		var kind: String = PlanetPin.drop(ball, i, 0).ground.kind
		if kind != "sea" and kind != "sea ice" and kind != "ice sheet": all_sea = false
	# 0% land still has plate ridges standing out of the deep, so not every pin need be sea.
	check("a global ocean's pins are all water or ice, or a ridge says why", all_sea or ball.climate.land == 0.0)
	var ice := spawn_world("ocean", 2.5, "Ice")
	var iced := 0
	for i in range(1, 30):
		if PlanetPin.drop(ice, i, 0).ground.kind in ["sea ice", "ice sheet"]: iced += 1
	check("an ice shell's pins are on ice (%d of 29)" % iced, iced >= 25)
	# Mapped worlds: Earth by its mask, Mars and the Moon as dry mosaics.
	var earth: Body = stage.state.body_named("Earth")
	var e_pin := PlanetPin.drop(earth, 3, 0)
	check("a pin on Earth agrees with its mask", (e_pin.ground.kind == "land" or e_pin.ground.kind == "ice sheet") == PlanetPin.land_at("Earth", e_pin.lat, e_pin.lon) or e_pin.ground.kind == "sea ice")
	check("a pin on Mars is dry", PlanetPin.drop(stage.state.body_named("Mars"), 1, 0).ground.kind in ["land", "ice sheet"])
	check("a pin on the Moon is dry", PlanetPin.drop(stage.state.body_named("Moon"), 1, 0).ground.kind == "land")
	for name_ in ["Wet", "Rock", "Ball", "Ice"]:
		stage.remove_body(stage.state.body_named(name_).id)
	PlanetPin.release_maps()
	star = star

# The measured grids against heights surveyed elsewhere. Each place catches a different misreading:
# rows flipped (the South Pole), east for west (Summit), the 0° E start (Olympus Mons, the Moon's
# summit), a unit or byte order (the means). A cell is a mean or median over a quarter degree, so a
# summit reads below its peak and a broad plateau reads as itself.
func measured() -> void:
	var d := PI / 180.0
	var earth := PlanetElevation.of("Earth")
	var mars := PlanetElevation.of("Mars")
	var moon := PlanetElevation.of("Moon")
	check("a grid for Earth, Mars and the Moon", earth != null and mars != null and moon != null)
	if earth == null or mars == null or moon == null: return
	check("and none for Io, which keeps the crust", PlanetElevation.of("Io") == null)
	check("quarter-degree grids", earth.width == 1440 and earth.height == 720 and mars.width == 1440 and moon.height == 720)
	# The PDS labels' projection offsets put a value at its cell's centre; ETOPO's 60″ blocks average to one.
	var off := 0.0
	for k in 40:
		var i := (k * 331) % mars.width
		var j := 5 + (k * 97) % (mars.height - 10)
		var la := (90.0 - (j + 0.5) * 0.25) * d
		var lo := ((i + 0.5) * 0.25 - 180.0) * d
		off = maxf(off, absf(mars.at(la, lo) - mars._cell(i, j)))
	check("a cell's value is at its centre (worst %.2f m)" % off, off < 0.01)
	# Wikipedia: Amundsen–Scott 2835 m, Summit Station 3216 m at 72.580° N 38.459° W, Lake Titicaca 3812 m
	# at 15.825° S 69.325° W.
	var pole := earth.at(-90.0 * d, 0.0)
	check("the South Pole's ice stands at 2835 m (%.0f)" % pole, near(pole, 2835.0, 150.0))
	var summit := earth.at(72.580 * d, -38.459 * d)
	check("Greenland's summit at 3216 m (%.0f)" % summit, near(summit, 3216.0, 150.0))
	var lake := earth.at(-15.825 * d, -69.325 * d)
	check("Lake Titicaca at 3812 m (%.0f)" % lake, near(lake, 3812.0, 300.0))
	# Charette & Smith 2010 via Wikipedia's Earth: oceans' mean depth 3682 m; land 29.2% of the surface.
	var s := _area_stats(earth)
	check("the ocean's mean depth is 3682 m (%.0f)" % s.sea_depth, near(s.sea_depth, 3682.0, 0.04 * 3682.0))
	check("29.2%% of the surface is above sea level (%.1f%%)" % (100.0 * s.above), near(s.above, 0.292, 0.015))
	# The Tibetan Plateau, centred at 33° N 88° E and 2500 km across, averages over 4500 m; a quarter
	# degree's mean is highest on it, not on Everest (8848.86 m at 27.988° N 86.925° E), whose cell
	# takes in its valleys.
	var top := _extreme(earth, 1.0)
	check("Earth's highest cell is on the Tibetan Plateau (%.2f° N %.2f° E)" % [top.lat, top.lon], _degrees_apart(top, 33.0, 88.0) < 11.2)
	var plateau := earth.at(33.0 * d, 88.0 * d)
	check("which stands over 4500 m (%.0f)" % plateau, plateau > 4500.0)
	var everest := earth.at(27.988 * d, 86.925 * d)
	check("Everest's cell is high and below its 8849 m (%.0f)" % everest, everest < 8848.86 and everest > 4500.0 and top.h < 8848.86)
	# Olympus Mons: 21.287 km above the MOLA datum at 18.65° N 226.20° E. Hellas: centred at 42.4° S
	# 70.5° E, its floor around 7152 m below the datum and the lowest ground on Mars.
	var olympus := _extreme(mars, 1.0)
	check("Mars's highest cell is Olympus Mons (%.2f° N %.2f° E)" % [olympus.lat, olympus.lon], _degrees_apart(olympus, 18.65, 226.20) < 1.5)
	check("a little under its 21.287 km (%.0f)" % olympus.h, olympus.h < 21287.0 and olympus.h > 20500.0)
	var hellas := _extreme(mars, -1.0)
	check("Mars's lowest is in Hellas (%.2f° N %.2f° E)" % [hellas.lat, hellas.lon], _degrees_apart(hellas, -42.4, 70.5) < 15.0)
	check("below its floor's 7152 m (%.0f)" % hellas.h, hellas.h < -7152.0)
	# The Moon: its summit at 5.441° N 158.656° W, 10.786 km; Antoniadi's pit at 70.43° S 187.42° E,
	# 9.178 km below the mean.
	var high := _extreme(moon, 1.0)
	check("the Moon's highest cell is its summit (%.2f° N %.2f° E)" % [high.lat, high.lon], _degrees_apart(high, 5.441, -158.656) < 0.5)
	check("a little under its 10.786 km (%.0f)" % high.h, high.h < 10786.0 and high.h > 10000.0)
	var low := _extreme(moon, -1.0)
	check("and its lowest Antoniadi's pit (%.2f° N %.2f° E)" % [low.lat, low.lon], _degrees_apart(low, -70.43, 187.42) < 0.5)
	check("9.178 km down (%.0f)" % low.h, near(low.h, -9178.0, 1000.0))
	# What a pin says with it.
	new_stage("solar")
	var e: Body = stage.state.body_named("Earth")
	var at_summit := PlanetPin.read_ground(e, PlanetPin.direction(72.580 * d, -38.459 * d), 72.580 * d, -38.459 * d)
	check("a pin on Summit reads its height (%.0f m)" % float(at_summit.height_m), near(float(at_summit.height_m), summit, 1.0))
	check("and says it was measured (%s)" % at_summit.text, String(at_summit.text).contains("ETOPO 2022") and not String(at_summit.text).contains("modelled"))
	var pacific := PlanetPin.read_ground(e, PlanetPin.direction(0.0, -150.0 * d), 0.0, -150.0 * d)
	check("mid-Pacific is open sea %.0f m deep" % float(pacific.depth_m), pacific.kind == "sea" and near(float(pacific.depth_m), -earth.at(0.0, -150.0 * d), 1.0) and float(pacific.depth_m) > 3000.0)
	var m: Body = stage.state.body_named("Mars")
	var on_olympus := PlanetPin.read_ground(m, PlanetPin.direction(18.65 * d, 226.2 * d), 18.65 * d, 226.2 * d)
	check("a pin on Olympus Mons is %.1f km up" % (float(on_olympus.height_m) / 1000.0), near(float(on_olympus.height_m), mars.at(18.65 * d, 226.2 * d), 1.0))
	# A coast the quarter degree blurs: the map's side wins, by a few metres.
	check("a land pin in a sea-averaged cell stands on land", PlanetPin.measured_km(earth, 0.0, -150.0 * d, true) > 0.0)
	check("a sea pin in a land-averaged cell is under water", PlanetPin.measured_km(earth, -15.825 * d, -69.325 * d, false) < 0.0)
	var worst := 0.0
	for i in 50:
		var la := (i * 3.5 - 86.0) * d
		var lo := (i * 7.3 - 179.0) * d
		var back := PlanetPin.lat_lon(PlanetPin.direction(la, lo))
		worst = maxf(worst, maxf(absf(back.x - la), absf(wrapf(back.y - lo, -PI, PI))))
	check("lat_lon undoes direction (worst %s rad)" % str(worst), worst < 1e-5)
	PlanetPin.release_maps()
	check("leaving the showcase lets the grids go", PlanetElevation._cache.is_empty())

func _area_stats(e: PlanetElevation) -> Dictionary:
	var sea_area := 0.0
	var sea_sum := 0.0
	var land_area := 0.0
	var total := 0.0
	for j in e.height:
		var w := cos(PI * 0.5 - PI * (j + 0.5) / e.height)
		for i in e.width:
			var h := e._cell(i, j)
			total += w
			if h < 0.0:
				sea_area += w
				sea_sum -= h * w
			else: land_area += w
	return {"sea_depth": sea_sum / sea_area, "above": land_area / total}

# The highest (sign 1) or lowest (−1) cell, in degrees east.
func _extreme(e: PlanetElevation, sign_: float) -> Dictionary:
	var best := -INF
	var at := Vector2i.ZERO
	for j in e.height:
		for i in e.width:
			var v := e._cell(i, j) * sign_
			if v > best:
				best = v
				at = Vector2i(i, j)
	return {"lat": 90.0 - (at.y + 0.5) * 180.0 / e.height, "lon": (at.x + 0.5) * 360.0 / e.width - 180.0, "h": best * sign_}

func _degrees_apart(c: Dictionary, lat: float, lon: float) -> float:
	var a := PlanetPin.direction(deg_to_rad(float(c.lat)), deg_to_rad(float(c.lon)))
	var b := PlanetPin.direction(deg_to_rad(lat), deg_to_rad(lon))
	return rad_to_deg(acos(clampf(a.dot(b), -1.0, 1.0)))
# A pin reads what the climate draws, whether or not a frame has been drawn and while the look still
# eases, and the same ground each time the world is loaded.
func honest_reads() -> void:
	var texts := {}
	for drawn in [false, true]:
		stage.set_drawn(drawn)
		new_stage("solar")
		if drawn:
			for i in 5: stage.animate(1.0 / 60.0)
		texts[drawn] = PlanetPin.drop(stage.state.body_named("Mars"), 1, 0).ground.text
	stage.set_drawn(true)
	check("a pin reads the same undrawn as drawn (%s | %s)" % [texts[false], texts[true]], texts[false] == texts[true])
	var w := spawn_world("earth", 1.0, "Eased", {"land": 0.3})
	stage.edit_body(w, {"land": 0.6})
	stage.animate(1.0 / 60.0)
	var mid: Dictionary = PlanetPin.drop(w, 2, 0).ground
	var started := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started < 2500: stage.animate(1.0 / 60.0)
	var settled: Dictionary = PlanetPin.drop(w, 2, 0).ground
	check("a pin dropped mid-ease reads where the look is going (%.0f m, %.0f m)" % [float(mid.height_m), float(settled.height_m)], mid.text == settled.text)
	stage.remove_body(w.id)
	# The crust is keyed by the world, not by how many bodies came before it.
	for name_ in ["Venus", "Mercury", "Pluto"]:
		var heights := []
		for round in 3:
			new_stage("solar")
			heights.append(float(PlanetPin.drop(stage.state.body_named(name_), 1, 0).ground.height_m))
		check("%s's pin 1 stands on the same ground over three loads (%s)" % [name_, str(heights)], heights[0] == heights[1] and heights[1] == heights[2])
	# Each world cools with height at its own rate, and the shader draws the same one.
	new_stage("solar")
	var moon: Body = stage.state.body_named("Moon")
	var mars: Body = stage.state.body_named("Mars")
	var earth: Body = stage.state.body_named("Earth")
	var mr := PlanetRelief.of_body(moon)
	check("the Moon has no air to cool with height", mr.lapse == 0.0 and mr.temperature(0.1, 8.0) == mr.temperature(0.1, -6.0))
	var r := PlanetRelief.of_body(mars)
	check("Mars cools at its own %.2f K/km, not Earth's 6.5" % r.lapse, r.lapse > 1.0 and r.lapse < 3.0)
	check("and Earth at its 6.5 (%.2f)" % PlanetRelief.of_body(earth).lapse, near(PlanetRelief.of_body(earth).lapse, 6.5, 0.3))
	check("a basin below a dry world's datum is warmer than the datum", r.temperature(0.6, r.altitude(-7.0, false)) > r.temperature(0.6, 0.0))
	check("the shader's lapse is the pin's", near(float(mars.viz.surf_mat.get_shader_parameter("uLapse")), r.lapse, 1e-6))
	# Heights keep their side.
	var g := {"kind": "land", "biome": "bare ground", "height_m": -6100.0, "temp_k": 230.0}
	check("a basin reads below the datum (%s)" % PlanetPin.describe(g, mars), PlanetPin.describe(g, mars).contains("6.1 km below the datum"))
	g.height_m = 6100.0
	check("a peak above it", PlanetPin.describe(g, mars).contains("6.1 km above the datum"))
	g.height_m = -400.0
	check("dry land below the sea reads so (%s)" % PlanetPin.describe(g, earth), PlanetPin.describe(g, earth).contains("400 m below sea level"))
	# A lesson owns the stage: no showcase from its focus panel, and one opened from the mode bar goes back to it.
	stage.state.focus_id = earth.id
	stage.refresh_ui()
	check("the focus panel offers a showcase", stage.hud.ids.showcaseOpen.visible)
	stage.set_app_mode("learn", {"quiet": true})
	check("but not during a lesson", not stage.hud.ids.showcaseOpen.visible)
	stage.set_app_mode("showcase", {"body": "Earth"})
	stage._on_showcase_action("leave")
	check("leaving goes back to the course it came from (%s)" % stage.state.app_mode, stage.state.app_mode == "learn")
	stage.set_app_mode("sandbox")
	PlanetPin.release_maps()

# The CPU crust's land share is what the crust threshold asks for: the shader's statistics did not
# move when its hash did. The doc's near-normal sd is the anchor.
func statistics() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 77
	var worlds := 40
	var n := 60
	var land := 0
	var sum := 0.0
	var sq := 0.0
	var threshold := Terrain.crust_threshold(0.29)
	# One world's sample covers a few lattice cells, so the statistics are over many seeds.
	for w in worlds:
		var seed_ := rng.randf() * 137.0
		for i in n:
			var z := rng.randf_range(-1.0, 1.0)
			var a := rng.randf() * TAU
			var q := sqrt(1.0 - z * z)
			var p := Vector3(q * cos(a), z, q * sin(a))
			var f := PlanetRelief.fbm(PlanetRelief.warp(p * 1.9 + Vector3(seed_, seed_, seed_), 0.55), 7)
			sum += f
			sq += f * f
			if f > threshold: land += 1
	var count := worlds * n
	var mean := sum / count
	var sd := sqrt(sq / count - mean * mean)
	print("PINCHECK fbm mean=%.4f sd=%.4f land=%.3f" % [mean, sd, float(land) / count])
	check("the fBm's mean stays near the threshold's 0.497 (%.4f)" % mean, near(mean, 0.497, 0.012))
	check("and its sd near 0.1065 (%.4f)" % sd, near(sd, 0.1065, 0.012))
	check("29%% land asks for 29%% land (%.1f%%)" % (100.0 * land / count), near(float(land) / count, 0.29, 0.035))

func panel_text(id: String) -> String:
	var el = stage.hud.ids.get(id)
	return String(el.text) if el != null else ""

# The mode's manners: enter, pin, leave, and nothing stays changed.
func mode_flow() -> void:
	new_stage("solar")
	var earth: Body = stage.state.body_named("Earth")
	stage.state.pin_on_focus = true
	var state = stage.state
	stage.set_follow(state.body_named("Jupiter"))
	stage.jump_cam_radius(11.0)
	stage.cam.theta = 1.1
	stage.cam.phi = 0.7
	stage.set_time_scale(0.123)
	state.speed = 1.5
	state.paused = true
	state.focus_id = earth.id
	var before := {"theta": stage.cam.theta, "phi": stage.cam.phi, "radius": stage.cam.radius, "follow": state.follow_id, "focus": state.focus_id,
		"time_scale": state.time_scale, "speed": state.speed, "paused": state.paused, "true": state.true_scale, "mode": state.cam_mode, "home": state.home_id}
	var bodies := {}
	for b: Body in state.bodies: bodies[b.id] = [b.mass, b.spec.duplicate(true), b.radius]
	stage.refresh_ui()
	check("the focus panel offers a world's showcase", stage.hud.ids.showcaseOpen.visible)
	stage._on_showcase_action("open")
	check("it opens on the focused world", stage.showcase.active and stage.showcase.body == earth)
	check("the app is in the mode", state.app_mode == "showcase")
	check("and it runs its clock", not state.paused)
	check("the panel names the world", panel_text("scWorld") == "Earth")
	check("no pin until it is in focus", stage.showcase.pin == null)
	for i in 400:
		stage.animate(1.0 / 60.0)
		if stage.showcase.pin != null: break
	check("a pin drops by itself once the world fills the view", stage.showcase.pin != null)
	check("the world fills it", stage.cam.radius <= earth.radius_scene * Showcase.FRAME_RADII * Showcase.SETTLED)
	var marker: Node3D = stage.showcase.marker
	check("the marker is on the surface mesh", marker != null and marker.get_parent() == earth.viz.surface)
	check("the panel says what it landed on", panel_text("scPinAt") != "—")
	var first := PlanetPin.drop(earth, 1, 0)
	check("it is the seed's first pin", stage.showcase.pin.lat == first.lat and stage.showcase.pin.lon == first.lon)
	var spin0: float = earth.spin_phase
	for i in 240: stage.animate(1.0 / 60.0)
	check("the ground keeps turning under the view", earth.spin_phase != spin0)
	# Rides with it: the pin stays on the camera's side.
	var viz = earth.viz
	var world: Vector3 = (viz.group.global_transform.basis * viz.surface.basis).orthonormalized() * stage.showcase.pin.p
	var to_cam := DVec3.new(sin(stage.cam.theta) * cos(stage.cam.phi), cos(stage.cam.theta), sin(stage.cam.theta) * sin(stage.cam.phi)).to_v3()
	check("the view rides with the pin (cos %.2f)" % world.dot(to_cam), world.dot(to_cam) > 0.35)
	check("the slab is out of the picture", not stage.spacetime_mesh.node.visible)
	stage._on_showcase_action("pin")
	check("another pin moves on", stage.showcase.pin.n == 2)
	var standing: int = PlanetPin._viz(earth).surface.get_children().filter(func(c): return String(c.name).begins_with("Pin") and not c.is_queued_for_deletion()).size()
	check("and only one marker stands (%d)" % standing, standing == 1)
	# A rebuild takes the marker with it; it comes back.
	stage.set_true_scale(not state.true_scale)
	stage.animate(1.0 / 60.0)
	check("a rebuilt visual gets its marker back", stage.showcase.marker != null and stage.showcase.marker.get_parent() == PlanetPin._viz(earth).surface)
	check("true scale: the marker is scaled to the world", stage.showcase.marker.get_child(0).mesh.height < earth.radius_scene * 0.2)
	stage.set_true_scale(not state.true_scale)
	stage.animate(1.0 / 60.0)
	stage._on_showcase_action("auto")
	check("the setting turns off", not state.pin_on_focus)
	stage._on_showcase_action("leave")
	check("leaving ends the mode", not stage.showcase.active and state.app_mode == "sandbox")
	var after := {"theta": stage.cam.theta, "phi": stage.cam.phi, "radius": stage.cam.radius, "follow": state.follow_id, "focus": state.focus_id,
		"time_scale": state.time_scale, "speed": state.speed, "paused": state.paused, "true": state.true_scale, "mode": state.cam_mode, "home": state.home_id}
	for k in before:
		check("leaving restores %s (%s)" % [k, after[k]], before[k] == after[k] or (before[k] is float and near(float(before[k]), float(after[k]), 1e-9)))
	check("no pin stands after", stage.showcase.marker == null and earth.viz.surface.get_children().filter(func(c): return c.name.begins_with("Pin") and not c.is_queued_for_deletion()).is_empty())
	var same := true
	for b: Body in state.bodies:
		if not bodies.has(b.id) or bodies[b.id][0] != b.mass or bodies[b.id][2] != b.radius or var_to_str(bodies[b.id][1]) != var_to_str(b.spec): same = false
	check("no body's mass, radius or spec moved", same)
	check("the map's mask is let go", PlanetPin._mask.is_empty())
	# With the setting off, a manual pin only.
	stage.set_app_mode("showcase", {"body": "Mars"})
	check("named by body", stage.showcase.body.name == "Mars")
	for i in 200: stage.animate(1.0 / 60.0)
	check("with the setting off nothing drops", stage.showcase.pin == null)
	stage._on_showcase_action("pin")
	check("a manual pin drops", stage.showcase.pin != null)
	# Removing the world ends the mode.
	var doomed: Body = stage.showcase.body
	stage.remove_body(doomed.id)
	stage.animate(1.0 / 60.0)
	check("removing the world ends the mode", not stage.showcase.active)
	stage.state.pin_on_focus = true
	# Loading a scenario ends it.
	new_stage("solar")
	stage.set_app_mode("showcase", {"body": "Venus"})
	stage.load_preset("sandbox")
	check("another scenario ends it", not stage.showcase.active)
	# A star's collapse or a merge: the world's climate goes.
	new_stage("solar")
	stage.set_app_mode("showcase", {"body": "Earth"})
	var e2: Body = stage.state.body_named("Earth")
	stage.transmute(e2, "gas-giant", "")
	stage.animate(1.0 / 60.0)
	check("a world that stops being one ends it", not stage.showcase.active)
	# A scenario with no world refuses.
	new_stage("bhmerger")
	stage.set_app_mode("showcase", {"body": ""})
	check("no rocky world: the mode refuses", not stage.showcase.active and stage.state.app_mode == "sandbox")
	new_stage("solar")
	stage.state.paused = true

# A scene's physics do not notice a showcase: two runs side by side, with and without.
func physics_parity() -> void:
	var run := func(visit: bool) -> String:
		new_stage("solar")
		stage.state.paused = false
		stage.set_time_scale(0.002)
		# A focused world's climate steps every frame, so both runs focus the same one.
		stage.state.focus_id = stage.state.body_named("Earth").id
		if visit: stage.set_app_mode("showcase", {"body": "Earth"})
		for i in 200: stage.step_physics(0.0005)
		var out := []
		for b: Body in stage.state.bodies:
			out.append([b.name, b.pos.to_array(), b.vel.to_array(), b.mass])
			if b.climate != null: out.append([b.climate.T, b.climate.ice])
		if visit: stage.set_app_mode("sandbox")
		return var_to_str(out)
	var plain: String = run.call(false)
	var shown: String = run.call(true)
	check("a showcase changes no orbit or climate", plain == shown)

func gpu_probe() -> void:
	new_stage("blank")
	var star: Body = stage.spawn_body({"type": "star", "mass": 1.0, "name": "Lamp", "radiusKm": 696000.0})
	star = star
	var worlds := [
		spawn_world("earth", 1.0, "Wet", {"land": 0.35}),
		spawn_world("bare", 1.0, "Cratered"),
	]
	for w: Body in worlds:
		var r := PlanetRelief.of_visual(PlanetPin._viz(w))
		var rng := RandomNumberGenerator.new()
		rng.seed = 5
		var n := 64
		var pts := Image.create(n, n, false, Image.FORMAT_RGBF)
		var dirs := []
		for j in n:
			for i in n:
				var z := rng.randf_range(-1.0, 1.0)
				var a := rng.randf() * TAU
				var q := sqrt(1.0 - z * z)
				var p := Vector3(q * cos(a), z, q * sin(a))
				dirs.append(p)
				pts.set_pixel(i, j, Color(p.x, p.y, p.z))
		var vp := SubViewport.new()
		vp.size = Vector2i(n, n)
		vp.disable_3d = true
		vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		vp.transparent_bg = false
		add_child(vp)
		var mat := ShaderMaterial.new()
		mat.shader = load("res://tools/terrain_probe.gdshader")
		mat.set_shader_parameter("uPoints", ImageTexture.create_from_image(pts))
		mat.set_shader_parameter("uSeed", r.seed)
		mat.set_shader_parameter("uCrater", r.crater)
		mat.set_shader_parameter("uCrustT", r.crust_t)
		mat.set_shader_parameter("uLandRelief", r.land_relief)
		mat.set_shader_parameter("uOceanDepth", r.ocean_depth)
		mat.set_shader_parameter("uPlateScale", r.plate_scale)
		var rect := ColorRect.new()
		rect.size = Vector2(n, n)
		rect.material = mat
		vp.add_child(rect)
		for i in 4: await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var img := vp.get_texture().get_image()
		var worst := 0.0
		var total := 0.0
		var count := 0
		var sign_miss := 0
		for j in n:
			for i in n:
				var c := img.get_pixel(i, j)
				var k: float = c.r + c.g / 255.0 + c.b / 65025.0
				var gpu := k * 80.0 - 40.0
				var cpu := r.height(dirs[j * n + i]).x
				var diff := absf(gpu - cpu)
				worst = maxf(worst, diff)
				total += diff
				count += 1
				if (gpu < r.sea_km) != (cpu < r.sea_km): sign_miss += 1
		print("PINCHECK GPU %s: mean diff %.1f m, worst %.1f m, sea/land disagreements %d of %d" % [w.name, 1000.0 * total / count, 1000.0 * worst, sign_miss, count])
		check("%s: the CPU's crust is the shader's, mean diff %.1f m" % [w.name, 1000.0 * total / count], total / count < 0.05)
		check("%s: worst point within 300 m (%.0f m)" % [w.name, 1000.0 * worst], worst < 0.3)
		check("%s: a pin never disagrees about sea and land" % w.name, sign_miss <= 1)
		vp.queue_free()

# End to end: the actual planet in the frame, its sea and land read off the pixels, against the CPU's.
func coast_in_the_frame() -> void:
	new_stage("blank")
	stage.state.show_mesh = false
	stage.state.show_lens = false
	stage.spacetime_mesh.node.visible = false
	stage.hud.set_hud_hidden(true)
	var star: Body = stage.spawn_body({"type": "star", "mass": 1.0, "name": "Lamp", "radiusKm": 696000.0})
	var b := spawn_world("earth", 1.0, "Coast", {"land": 0.45, "cloudCover": 0.0, "biota": 0.0, "regolith": 0xc08040})
	var viz = PlanetPin._viz(b)
	# The whole disc, lit from behind the camera.
	stage.set_follow(b)
	var d: DVec3 = star.pos.sub(b.pos).normalized()
	stage.cam.phi = atan2(d.z, d.x)
	stage.cam.theta = acos(clampf(d.y, -1.0, 1.0))
	stage.jump_cam_radius(b.radius_scene * 2.6)
	for i in 30:
		stage.animate(1.0 / 60.0)
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	if args.has("out"): img.save_png("%s/coast.png" % args.out)
	var r := PlanetRelief.of_visual(viz)
	var cam: Camera3D = stage.pipe.scene_cam
	var view := Vector2(stage.pipe.view_size)
	var scale_x := view.x / img.get_width()
	var center := b.scene_pos.rel_v3(stage.cam_pos)
	var R: float = viz.R
	var turn: Basis = (viz.group.global_transform.basis * viz.surface.basis).orthonormalized().inverse()
	var rng := RandomNumberGenerator.new()
	rng.seed = 9
	var agree := 0
	var total := 0
	var tries := 0
	while total < 600 and tries < 20000:
		tries += 1
		var px := Vector2i(rng.randi_range(0, img.get_width() - 1), rng.randi_range(0, img.get_height() - 1))
		var ray := cam.project_ray_normal(Vector2(px) * scale_x)
		var b_ := ray.dot(center)
		var disc := b_ * b_ - center.length_squared() + R * R
		if disc <= 0.0: continue
		var hit := ray * (b_ - sqrt(disc)) - center
		if hit.normalized().dot(-ray) < 0.6: continue
		var p := (turn * hit).normalized()
		var h := r.height(p).x
		# Leave the shore itself, where a pixel straddles the line.
		if absf(h - r.sea_km) < 0.25: continue
		var c := img.get_pixelv(px)
		var drawn_sea := c.b > c.r
		if drawn_sea == (h < r.sea_km): agree += 1
		total += 1
	print("PINCHECK coast %d of %d pixels agree" % [agree, total])
	check("the frame's sea and land are the CPU's (%d of %d)" % [agree, total], total >= 200 and float(agree) / total > 0.97)

func marker_pixels() -> void:
	new_stage("blank")
	stage.state.show_mesh = false
	stage.state.show_lens = false
	stage.spacetime_mesh.node.visible = false
	var star: Body = stage.spawn_body({"type": "star", "mass": 1.0, "name": "Lamp", "radiusKm": 696000.0})
	star = star
	spawn_world("bare", 1.0, "Stage")
	stage.hud.set_hud_hidden(true)
	stage.state.pin_on_focus = true
	stage.set_app_mode("showcase", {"body": "Stage"})
	var started := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started < 5000:
		stage.animate(1.0 / 60.0)
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	if args.has("out"): img.save_png("%s/showcase.png" % args.out)
	var red := 0
	for j in range(0, img.get_height(), 2):
		for i in range(0, img.get_width(), 2):
			var c := img.get_pixel(i, j)
			if c.r > c.g * 1.5 and c.r > c.b * 1.5 and c.r > 0.3: red += 1
	print("PINCHECK marker pixels %d" % red)
	check("the pin shows in the frame (%d px)" % red, red >= 10)
	stage.set_app_mode("sandbox")

func _ready() -> void:
	OS.add_logger(catcher)
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else ""
	stage = load("res://main.tscn").instantiate()
	add_child(stage)
	for i in 2: await get_tree().process_frame
	stage._start("sandbox")
	stage.set_process(false)
	if args.get("gpu", "0") == "1":
		await gpu_probe()
		await coast_in_the_frame()
		await marker_pixels()
	else:
		statistics()
		draws()
		ground_reads()
		measured()
		honest_reads()
		mode_flow()
		physics_parity()
	for i in 3: await get_tree().process_frame
	for error in catcher.take(): check("engine: " + str(error), false)
	print("PINCHECK DONE checks=%d failures=%d" % [checks, failures])
	get_tree().quit(1 if failures else 0)
