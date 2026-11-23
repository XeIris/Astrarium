extends Node

# GROUND CHECK: a vehicle coming down on a dry mapped world lands on the ground that is drawn
# (sim/surface/surface_ground.gd, docs/physics/surface.md#the-ground-under-a-landing). The frames agree,
# the contact sampler is the mesh's own triangles, the LM and the Sky Crane touch down on the drawn site
# with the measured grid under them, drawn and undrawn flights land alike, Earth keeps its figure, and
# nothing of a landing outlives its flight.
#   Godot --headless --path . res://tools/groundcheck.tscn

var main: Node
var failures := 0
var checks := 0

func check(what: String, ok: bool) -> void:
	checks += 1
	if ok: print("GROUNDCHECK ok   ", what)
	else:
		failures += 1
		printerr("GROUNDCHECK FAIL ", what)

func _ready() -> void:
	PlanetMaps.synchronous = true
	get_viewport().set_disable_input(true)
	main = Node.new()
	main.name = "Main"
	main.set_script(load("res://main.gd"))
	add_child(main)
	main.set_process(false)
	for i in 4: await get_tree().process_frame
	_frames()
	SurfaceStats.reset()
	await _land("lm:terminal_descent", "Moon")
	await _land("skycrane:sky_crane", "Mars")
	await _parity("skycrane:sky_crane")
	_measured_relief()
	await _earth()
	main.flight.teardown()
	var c := SurfaceStats.calls
	check("every landing ground and drawn site was let go (grounds %d/%d, sites %d/%d)" % [int(c.get("ground_init", 0)),
		int(c.get("ground_dispose", 0)), int(c.get("site_init", 0)), int(c.get("site_dispose", 0))],
		int(c.get("ground_init", 0)) > 0 and c.get("ground_init", 0) == c.get("ground_dispose", 0)
		and c.get("site_init", 0) == c.get("site_dispose", 0))
	print("GROUNDCHECK DONE checks=%d failures=%d" % [checks, failures])
	get_tree().quit(1 if failures > 0 else 0)

# The flight frame (pole on −Y, prime meridian turned by θ) against the planet mesh's (PlanetPin).
func _frames() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var trip := 0.0
	var angle := 0.0
	var dir := 0.0
	for i in 400:
		var theta := rng.randf_range(-PI, PI)
		var lat := asin(rng.randf_range(-0.999, 0.999))
		var lon := rng.randf_range(-PI, PI)
		var R := 3.39e6
		var rr := DVec3.new(R * cos(lat) * cos(lon + theta), -R * sin(lat), R * cos(lat) * sin(lon + theta))
		var m := SurfaceGround.to_mesh(rr, theta, DVec3.new())
		trip = maxf(trip, SurfaceGround.from_mesh(m, theta, DVec3.new()).sub(rr).length())
		var ll := SurfaceGround.lat_lon(m)
		angle = maxf(angle, absf(ll[0] - lat) + absf(wrapf(ll[1] - lon, -PI, PI)))
		dir = maxf(dir, (Vector3(m.x, m.y, m.z) / R - PlanetPin.direction(lat, lon)).length())
	check("flight → mesh → flight returns the point (worst %s m)" % U.expo(trip, 1), trip < 1e-6)
	check("a flight-frame point reads its own latitude and east longitude (worst %s rad)" % U.expo(angle, 1), angle < 1e-9)
	check("the mesh direction is PlanetPin's (worst %s)" % U.expo(dir, 1), dir < 1e-6)

func _land(spec: String, world: String) -> void:
	var err: String = await main.jump_scenario(spec)
	check("%s: jump (%s)" % [spec, err if err != "" else "ok"], err == "")
	if err != "": return
	var f: Spaceflight = main.flight
	var v: Vessel = f.vessel
	check("%s: on %s with a ground under it" % [spec, world], v.parent.name == world and v.ground != null)
	if v.ground == null: return
	main.set_drawn(false)
	var n := 0
	while v.phase != Vessel.PHASE.LANDED and v.phase != Vessel.PHASE.DESTROYED and n < 40000:
		main.step_flight(0.05)
		n += 1
	main.set_drawn(true)
	check("%s: touched down (%s, %d frames)" % [spec, v.failure if v.failure else v.phase, n], v.phase == Vessel.PHASE.LANDED)
	var g: SurfaceGround = v.ground
	check("%s: the survey is the ground" % spec, g.adopted)
	var asked := -1.0
	var stood := -1.0
	for e in v.events:
		if str(e.msg).begins_with("Surveying the ground"): asked = float(e.t)
		if str(e.msg).begins_with("Standing on the surveyed ground"): stood = float(e.t)
	check("%s: stood on it %s s after asking, %s s by the clock" % [spec, U.fixed(stood - asked, 2), U.fixed(SurfaceGround.ADOPT_S, 0)],
		asked >= 0.0 and absf(stood - asked - SurfaceGround.ADOPT_S) < 1.0)
	check("%s: the gear is on the ground (%s m)" % [spec, U.fixed(v.contact_altitude(), 4)], absf(v.contact_altitude()) < 0.01)
	var terrain := v.altitude() - v.height_above_ground()
	var ll := SurfaceGround.lat_lon(SurfaceGround.to_mesh(v.r, v.body_angle(v.coord), DVec3.new()))
	var measured := g.elevation.at(ll[0], ll[1])
	check("%s: the ground stands off the figure (%s m; the measured cell %s m)" % [spec, U.fixed(terrain, 1), U.fixed(measured, 1)],
		absf(terrain) > 1.0)
	# Drawn: the site is built on a drawn frame. Where the vehicle is, read off the nodes as placed.
	for i in 3: main.animate(1.0 / 60.0)
	var site: SurfaceSite = f.ground_site
	check("%s: the surveyed site is drawn" % spec, site != null and site.built)
	if site == null or not site.built: return
	var inv := site.group.global_transform.affine_inverse()
	var at: Vector3 = inv * f.craft.group.global_position
	var meshes := _meshes(site)
	var drawn_y := _mesh_y(meshes, site.relief.grids, -at.x, at.z)
	var gap := at.y - drawn_y
	check("%s: over the drawn mesh by what physics says (%s m drawn, %s m physics)" % [spec, U.fixed(gap, 3), U.fixed(v.height_above_ground(), 3)],
		absf(gap - v.height_above_ground()) < 0.05)
	_sampler(spec, site, meshes)

# The contact sampler against the triangles as built, over both grids.
func _sampler(spec: String, site: SurfaceSite, meshes: Array) -> void:
	var grids: Array = site.relief.grids
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var worst := 0.0
	for gi in 2:
		var half: float = grids[gi].half
		for i in 1500:
			var e := rng.randf_range(-half * 0.999, half * 0.999)
			var n := rng.randf_range(-half * 0.999, half * 0.999)
			var a := SiteScene.drawn_height(grids, e, n, site.patch_y, site.relief.radius_m, false)
			var b := _mesh_y(meshes, grids, e, n)
			worst = maxf(worst, absf(a - b))
	check("%s: SiteScene.drawn_height is the mesh (worst %s m over 3000 points)" % [spec, U.expo(worst, 1)], worst < 2e-3)

func _meshes(site: SurfaceSite) -> Array:
	var out := []
	for name in ["terrain_0", "terrain_1"]:
		var mi := site.group.find_child(name, false, false) as MeshInstance3D
		var arr := mi.mesh.surface_get_arrays(0)
		var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
		var first := {}
		for t in range(0, idx.size(), 3): first[idx[t]] = (first.get(idx[t], []) as Array) + [t]
		out.append({"v": arr[Mesh.ARRAY_VERTEX], "i": idx, "first": first})
	return out

# The height of the built mesh at metres east `e` and north `n` (x runs west): the triangle containing it,
# found in the index buffer, interpolated on its own vertices.
func _mesh_y(meshes: Array, grids: Array, e: float, n: float) -> float:
	for gi in 2:
		var g: Dictionary = grids[gi]
		var half: float = g.half
		if absf(e) >= half or absf(n) >= half: continue
		var cells: int = int(g.n) - 1
		var step := 2.0 * half / cells
		var i := mini(int((e + half) / step), cells - 1)
		var j := mini(int((n + half) / step), cells - 1)
		var m: Dictionary = meshes[gi]
		var verts: PackedVector3Array = m.v
		var idx: PackedInt32Array = m.i
		var p := Vector2(-e, n)
		for start in [j * g.n + i, j * g.n + i + 1]:
			for t in (m.first.get(start, []) as Array):
				var a := verts[idx[t]]
				var b := verts[idx[t + 1]]
				var c := verts[idx[t + 2]]
				var w := _bary(p, Vector2(a.x, a.z), Vector2(b.x, b.z), Vector2(c.x, c.z))
				if w.x >= -1e-6 and w.y >= -1e-6 and w.z >= -1e-6:
					return a.y * w.x + b.y * w.y + c.y * w.z
	return NAN

static func _bary(p: Vector2, a: Vector2, b: Vector2, c: Vector2) -> Vector3:
	var d := (b.y - c.y) * (a.x - c.x) + (c.x - b.x) * (a.y - c.y)
	var u := ((b.y - c.y) * (p.x - c.x) + (c.x - b.x) * (p.y - c.y)) / d
	var w := ((c.y - a.y) * (p.x - c.x) + (a.x - c.x) * (p.y - c.y)) / d
	return Vector3(u, w, 1.0 - u - w)

# The same descent flown drawn and undrawn lands at the same place and moment.
func _parity(spec: String) -> void:
	var out := []
	for drawn in [false, true]:
		var err: String = await main.jump_scenario(spec)
		if err != "":
			check("%s: parity jump (%s)" % [spec, err], false)
			return
		var v: Vessel = main.flight.vessel
		main.set_drawn(drawn)
		var n := 0
		while v.phase != Vessel.PHASE.LANDED and v.phase != Vessel.PHASE.DESTROYED and n < 40000:
			main.step_flight(0.05)
			n += 1
		main.set_drawn(true)
		var ll := SurfaceGround.lat_lon(SurfaceGround.to_mesh(v.r, v.body_angle(v.coord), DVec3.new()))
		out.append({"met": v.met, "lat": ll[0], "lon": ll[1], "r": v.r.length()})
	var d_m: float = (absf(out[0].lat - out[1].lat) + absf(out[0].lon - out[1].lon)) * main.flight.vessel.env.radius
	check("%s: drawn and undrawn touch down together (%s s, %s m apart, %s m in radius)" % [spec,
		U.fixed(absf(out[0].met - out[1].met), 3), U.fixed(d_m, 4), U.fixed(absf(out[0].r - out[1].r), 4)],
		absf(out[0].met - out[1].met) < 1e-6 and d_m < 1e-4 and absf(out[0].r - out[1].r) < 1e-4)

# On a measured dry world the survey keeps the measured ground: the sub-cell relief carries the cell's own
# roughness down by the world's Hurst exponent. LOLA's median slopes (Rosenburg et al. 2011, 17 m
# baseline: maria 2.0°, highlands 7.5°) are read at the near grid's 50 m, where the same Hursts give
# about 1.5° and 7.1°; neither number is an input.
func _measured_relief() -> void:
	var f: Spaceflight = main.flight
	var cases := [["Moon", "Mare Tranquillitatis", 0.674, 23.473, [0.5, 4.0]], ["Moon", "farside highlands", -5.0, 160.0, [3.0, 14.0]],
		["Mars", "Jezero", 18.38, 77.58, [0.0, 14.0]], ["Mars", "Tharsis plains", 5.0, -110.0, [0.0, 14.0]]]
	var slopes := {}
	for c in cases:
		var b: Body = f.body_named(str(c[0]))
		var pin := PlanetPin.at(b, deg_to_rad(float(c[2])), deg_to_rad(float(c[3])))
		var relief := SurfaceSite.plan_relief(b, pin, PlanetRelief.of_body(b), SurfaceGround.CELLS, SurfaceSite.site_seed(b, pin, 0))
		relief.build()
		var near: Dictionary = relief.grids[0]
		var med := _median_slope(near)
		slopes[c[1]] = med
		var nu := float(relief.stats.cell_roughness_m)
		var off := SiteScene.sample(relief.grids, 0.0, 0.0) - relief.elevation.at(pin.lat, pin.lon)
		var win: Array = c[4]
		check("%s, %s: median slope %s° at %s m (window %s–%s°); the cell's roughness %s m over %s km" % [c[0], c[1], U.fixed(med, 2),
			U.fixed(2.0 * float(near.half) / (int(near.n) - 1), 0), win[0], win[1], U.fixed(nu, 1), U.fixed(float(relief.stats.cell_m) / 1000.0, 1)],
			med >= float(win[0]) and med <= float(win[1]))
		check("%s, %s: the site stands %s m off its measured cell, inside 3 of its cell-scale roughness" % [c[0], c[1], U.fixed(off, 1)],
			absf(off) <= 3.0 * maxf(nu, 1.0))
	check("the highlands are rougher than the mare (%s° against %s°; LOLA's ratio at 17 m is 3.8)" % [
		U.fixed(slopes["farside highlands"], 2), U.fixed(slopes["Mare Tranquillitatis"], 2)],
		slopes["farside highlands"] > 2.0 * slopes["Mare Tranquillitatis"])

# Median of |Δh| / spacing between neighbouring cells, as an angle, °.
func _median_slope(g: Dictionary) -> float:
	var n: int = g.n
	var h: PackedFloat32Array = g.h
	var step := 2.0 * float(g.half) / (n - 1)
	var all := PackedFloat32Array()
	for j in n - 1:
		for i in n - 1:
			all.append(absf(h[j * n + i + 1] - h[j * n + i]) / step)
			all.append(absf(h[(j + 1) * n + i] - h[j * n + i]) / step)
	all.sort()
	return rad_to_deg(atan(all[all.size() / 2]))

# A world with seas and launch sites keeps its figure: no ground, and nothing of the surface runs.
func _earth() -> void:
	main.flight.teardown()
	var before := SurfaceStats.total()
	var err: String = await main.jump_scenario("falcon9:liftoff")
	check("falcon9:liftoff: jump (%s)" % (err if err != "" else "ok"), err == "")
	if err != "": return
	var v: Vessel = main.flight.vessel
	for i in 60: main.animate(1.0 / 60.0)
	check("Earth: no ground model, the figure is the ground", v.ground == null and v.height_above_ground() == v.altitude())
	var ran := SurfaceStats.total() - before
	check("Earth: nothing of the surface ran (%d)" % ran, ran == 0)
