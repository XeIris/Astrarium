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
	await _drive_lrv()
	await _edl()
	await _land("skycrane:sky_crane", "Mars")
	await _drive_perseverance()
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

# The Sky Crane from its parachute to the ground, with the frame loop's drawing (undrawn): what is packed clears
# what it is packed in, the shell goes up on its parachute and not down through the stack, and the sequence keeps
# NASA's times (docs/physics/sky-crane.md).
func _edl() -> void:
	var err: String = await main.jump_scenario("skycrane:parachute")
	check("skycrane:parachute: jump (%s)" % (err if err != "" else "ok"), err == "")
	if err != "": return
	var f: Spaceflight = main.flight
	var v: Vessel = f.vessel
	var shell = f.craft.stage("shell")
	# A craft of its own: the flying one's bells carry plumes.
	var spare := CraftModel.build_craft(v.vehicle)
	var packed := _packed(spare)
	spare.group.free()
	check("packed, the rover clears the heat shield by %s m and the backshell by %s m" % [U.fixed(packed[0], 3), U.fixed(packed[1], 3)],
		packed[0] > 0.03 and packed[1] > 0.0)
	main.set_drawn(false)
	var low := 0.0
	var at_light := -INF
	var sep := -1.0
	# The shell's plane, measured on the turning ground: where the stack was as the shell went, and which way it
	# was going over it.
	var was := Vector2.ZERO
	var before := Vector2.ZERO
	var heading := Vector2.ZERO
	var n := 0
	while not (v.phase in [Vessel.PHASE.LANDED, Vessel.PHASE.DESTROYED]) and n < 20000:
		f.finish_frame(1.0 / 30.0, main.step_flight(1.0 / 30.0))
		n += 1
		if v.ground.adopted and heading == Vector2.ZERO:
			var sp := v.ground.site_point(v, v.r)
			before = was
			was = Vector2(sp.x, sp.z)
			if f.autopilot._sep_met >= 0.0: heading = (was - before).normalized()
		if f.autopilot != null and f.autopilot._sep_met >= 0.0 and shell.sep != null:
			sep = f.autopilot._sep_met
			low = minf(low, shell.group.position.y)
			if at_light == -INF and float(v.telemetry.get("thrust", 0.0)) > 0.0: at_light = shell.group.position.y
	main.set_drawn(true)
	var at := {}
	for e in v.events:
		for k in ["Parachute deploy", "Heat shield separation", "Backshell separation", "Divert", "Sky crane", "Touchdown"]:
			if str(e.msg).begins_with(k) and not at.has(k): at[k] = float(e.t)
	check("it lands (%s)" % (v.failure if v.failure else v.phase), v.phase == Vessel.PHASE.LANDED)
	if at.size() < 6:
		check("every event is flown (%s)" % str(at.keys()), false)
		return
	check("the backshell rises off the stack (lowest %s m), %s m clear when the engines light" % [U.fixed(low, 2), U.fixed(at_light, 1)],
		low > -0.05 and at_light > 8.0)
	check("the heat shield %s s after the parachute (Perseverance: 20)" % U.fixed(at["Heat shield separation"] - at["Parachute deploy"], 1),
		absf(at["Heat shield separation"] - at["Parachute deploy"] - 20.0) < 0.2)
	check("it falls %s s before it lights (Tianwen-1: about 1)" % U.fixed(at.Divert - at["Backshell separation"], 2),
		absf(at.Divert - at["Backshell separation"] - 1.0) < 0.1)
	check("backshell to touchdown in %s s (Perseverance: 60)" % U.fixed(at.Touchdown - at["Backshell separation"], 1),
		absf(at.Touchdown - at["Backshell separation"] - 60.0) < 10.0)
	check("rover separation to touchdown in %s s (NASA: about 12)" % U.fixed(at.Touchdown - at["Sky crane"], 1),
		absf(at.Touchdown - at["Sky crane"] - 12.0) < 2.0)
	var sp1 := v.ground.site_point(v, v.r)
	var off := absf((Vector2(sp1.x, sp1.z) - was).cross(heading))
	check("down at %s m/s, %s m/s sideways, %s m out of the plane the shell falls in (MSL: 300, Perseverance: at most 600)" % [
		U.fixed(absf(float(v.landed_at.vVert)), 2), U.fixed(float(v.landed_at.vHoriz), 2), U.fixed(off, 0)],
		float(v.landed_at.vHoriz) < 0.3 and off > 280.0 and off < 620.0)
	for i in 300: f.finish_frame(0.05, main.step_flight(0.05))
	check("once the bridle is cut the vessel's reference is on the ground (%s m)" % U.fixed(v.height_above_ground(), 4),
		absf(v.height_above_ground()) < 0.01 and absf(v.contact_altitude()) < 0.01)
	f.teardown()

# The held descent rate is held against the ground: drifting across the steepest slope there is under her, the law
# asks for what closes on the ground at the touchdown rate, not for that rate against the planet's centre.
func _held_rate(f: Spaceflight) -> void:
	var v: Vessel = f.vessel
	var ap = f.autopilot
	var up := DQuat.nrm(v.r.clone())
	var kept := v.v.clone()
	var kept_site = ap.site
	ap.site = null
	var east := DQuat.nrm(DVec3.new(0.0, -1.0, 0.0).cross(up))
	var north := DQuat.nrm(up.clone().cross(east))
	var best := 0.0
	var along := east
	for k in 16:
		var d := east.clone().scale_in(cos(TAU * k / 16.0)).add_scaled_in(north, sin(TAU * k / 16.0))
		v.v.copy_from(kept).add_scaled_in(d, 6.0)
		var diff := absf(v.closing_rate(v.ground_velocity(v.r, v.v, DVec3.new())) - v.v.dot(up))
		if diff > best:
			best = diff
			along = d
	v.v.copy_from(kept).add_scaled_in(along, 6.0)
	var closing := v.closing_rate(v.ground_velocity(v.r, v.v, DVec3.new()))
	var cmd: DVec3 = ap.descent_law(10.0, 0.75, 0.35, 1.8, 0.55, 32.0, 1e4)
	var g: float = v.env.mu / v.r.length_sq()
	var want := g + (-0.75 - closing) / 1.8
	check("the held rate is against the ground: %s m/s of it is the slope's, and the law asks for %s of %s m/s²" % [U.fixed(best, 2),
		U.fixed(cmd.dot(up), 3), U.fixed(want, 3)], best > 0.1 and absf(cmd.dot(up) - want) < 0.3 * best / 1.8)
	v.v.copy_from(kept)
	ap.site = kept_site

# How far the packed rover's and descent stage's vertices are over the heat shield and inside the backshell, m.
func _packed(c: CraftModel.Craft) -> Array:
	var shield := []
	_verts(c.stage("shell").group.find_child("heatshield", true, false), Transform3D(), shield)
	var prof := {}
	for p: Vector3 in shield:
		var k := snappedf(Vector2(p.x, p.z).length(), 0.05)
		prof[k] = maxf(prof.get(k, -INF), p.y)
	var ks := prof.keys()
	ks.sort()
	var D: float = c.stage("shell").spec.D
	var over := INF
	var inside := INF
	for key in ["rover", "desc"]:
		var vs := []
		_verts(c.stage(key).group, Transform3D(), vs)
		for p: Vector3 in vs:
			var r := Vector2(p.x, p.z).length()
			for i in range(1, ks.size()):
				if r > ks[i]: continue
				over = minf(over, p.y - lerpf(prof[ks[i - 1]], prof[ks[i]], (r - ks[i - 1]) / (ks[i] - ks[i - 1])))
				break
			# The cone: from D/2 at 0.30 D up to 0.19 D at 0.80 D.
			var t := (p.y - 0.30 * D) / (0.5 * D)
			if t > 0.0: inside = minf(inside, (lerpf(0.5 * D, 0.19 * D, t) if t < 1.0 else 0.0) - r)
	return [over, inside]

func _verts(node: Node, xf: Transform3D, out: Array) -> void:
	var t := xf * (node as Node3D).transform if node is Node3D else xf
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		for k in (node as MeshInstance3D).mesh.get_surface_count():
			for p: Vector3 in (node as MeshInstance3D).mesh.surface_get_arrays(k)[Mesh.ARRAY_VERTEX]: out.append(t * p)
	for ch in node.get_children(): _verts(ch, t, out)

func _land(spec: String, world: String) -> void:
	var err: String = await main.jump_scenario(spec)
	check("%s: jump (%s)" % [spec, err if err != "" else "ok"], err == "")
	if err != "": return
	var f: Spaceflight = main.flight
	var v: Vessel = f.vessel
	check("%s: on %s with a ground under it" % [spec, world], v.parent.name == world and v.ground != null)
	if v.ground == null: return
	if spec.begins_with("skycrane"): _held_rate(f)
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

# The LRV off the LM that just landed, driven across the surveyed site: every wheel on the drawn triangles,
# sunk by the soil, the model drawn where the physics is, and nothing left after the flight.
func _drive_lrv() -> void:
	var f: Spaceflight = main.flight
	check("the landed LM can put its rover down", f.can_deploy_rover())
	check("and does", f.deploy_rover())
	if f.rover == null: return
	var r: Rover = f.rover
	var start := r.pos.clone()
	r.throttle = 1.0
	r.steer = 0.25
	main.set_drawn(false)
	for i in 30 * 20: main.step_flight(0.05)
	main.set_drawn(true)
	var moved := r.pos.sub(start).length()
	check("it drives off across the site (%s m in 30 s, %s km/h)" % [U.fixed(moved, 1), U.fixed(r.speed() * 3.6, 1)], moved > 20.0)
	var site: SurfaceSite = f.ground_site
	var worst := 0.0
	var touching := 0
	for wh: Rover.Wheel in r.wheels:
		if not wh.contact: continue
		touching += 1
		var cp: DVec3 = wh.contact_point
		var drawn := SiteScene.drawn_height(site.relief.grids, -cp.x, cp.z, site.patch_y, site.relief.radius_m, false)
		worst = maxf(worst, absf(cp.y + wh.sinkage - drawn))
	check("%d wheels on the ground, each on the drawn triangles less its sinkage (worst %s m)" % [touching, U.expo(worst, 1)], touching >= 3 and worst < 1e-6)
	for i in 3: main.animate(1.0 / 60.0)
	check("the LRV is drawn where the physics has it", f.rover_model != null and f.rover_model.group.is_inside_tree()
		and f.rover_model.group.position.distance_to(r.pos.to_v3()) < 0.5)
	var tracks := 0
	for p: Array in f.rover_tracks.paths: tracks += p.size()
	check("and it leaves tracks (%d points)" % tracks, tracks > 100)
	var model := f.rover_model.group
	f.teardown()
	await get_tree().process_frame
	check("nothing of it is left after the flight", f.rover == null and not is_instance_valid(model))

# Perseverance, taken over from the Sky Crane where it touched down: on the drawn triangles, driven, its
# turret put on the drawn ground ahead.
func _drive_perseverance() -> void:
	var f: Spaceflight = main.flight
	# What the rig draws once she is down: her wheels at the vessel's reference, where the physics put the
	# ground, and the descent stage gone off on its flyaway (or still climbing clear of her).
	var rig: SkyCraneRig = f.crane_rig
	check("the Sky Crane is drawn by its rig", rig != null)
	if rig != null:
		for i in 3: main.animate(1.0 / 60.0)
		var since := f.vessel.met - float(f.vessel.landed_at.met)
		var wheels := f.vessel.height_above_ground() + rig.rover.group.position.y
		check("her wheels drawn on the ground (%s m) %s s after touchdown, the bridles %s" % [U.fixed(wheels, 3), U.fixed(since, 2),
			"on" if rig.bridles[0].visible else "cut"], absf(wheels) < 0.01 and rig.bridles[0].visible == (since < SkyCraneRig.CUT_S))
		check("the descent stage over her by the bridle (%s m)" % U.fixed(rig.desc.group.position.y - rig.rover.group.position.y, 2),
			rig.desc.group.position.y - rig.rover.group.position.y > 8.0 or not rig.desc.group.visible)
	# A jet raises dust from about where it was seen to: the LM's 24 kN hover near 30 m and not from twice that, the
	# descent stage's 8.5 kN in Mars' air from 25 m.
	var onset := PlumeDust.ONSET_PA
	check("a landing jet raises dust where Apollo's crews and PIA24428 saw it start (LM %.1f Pa at 30 m, %.1f at 60; MSL %.0f at 25)"
		% [PlumeDust.ground_pressure(24e3, 30.0, false), PlumeDust.ground_pressure(24e3, 60.0, false), PlumeDust.ground_pressure(8.5e3, 25.0, true)],
		PlumeDust.ground_pressure(24e3, 30.0, false) > onset and PlumeDust.ground_pressure(24e3, 60.0, false) < onset
		and PlumeDust.ground_pressure(8.5e3, 25.0, true) > onset)
	check("the Sky Crane's rover can drive off", f.can_deploy_rover() and f.deploy_rover())
	if f.rover == null: return
	var r: Rover = f.rover
	check("it is Perseverance, where the stage touched down", str(r.spec.name) == "Perseverance"
		and Vector2(r.pos.x, r.pos.z).distance_to(Vector2(f.vessel.ground.site_point(f.vessel, f.vessel.r).x, f.vessel.ground.site_point(f.vessel, f.vessel.r).z)) < 0.5)
	var start := r.pos.clone()
	r.throttle = 1.0
	main.set_drawn(false)
	for i in 20 * 120: main.step_flight(0.05)
	var moved := r.pos.sub(start).length()
	check("it drives %s m in two minutes (%s m/h)" % [U.fixed(moved, 2), U.fixed(moved / 120.0 * 3600.0, 0)], moved > 3.0 and moved < 5.2)
	r.throttle = 0.0
	for i in 20 * 10: main.step_flight(0.05)
	var aim := f.rover_ground_ahead(1.5)
	check("the arm reaches the ground 1.5 m ahead", f.rover_arm.reach(aim))
	for i in 20 * 90: main.step_flight(0.05)
	main.set_drawn(true)
	var face := RoverArm.tip(f.rover_arm.joints)
	var world := r.pos.clone().add_in(DQuat.rotate(DVec3.from_v3(face), r.q))
	var site: SurfaceSite = f.ground_site
	var drawn := SiteScene.drawn_height(site.relief.grids, -world.x, world.z, site.patch_y, site.relief.radius_m, false)
	check("its turret stands on the drawn ground (%s m over it)" % U.fixed(world.y - drawn, 3), f.rover_arm.placed and absf(world.y - drawn) < 0.02)
	var worst := 0.0
	for wh: Rover.Wheel in r.wheels:
		if not wh.contact: continue
		var cp: DVec3 = wh.contact_point
		worst = maxf(worst, absf(cp.y + wh.sinkage - SiteScene.drawn_height(site.relief.grids, -cp.x, cp.z, site.patch_y, site.relief.radius_m, false)))
	check("its wheels on the drawn triangles less their sinkage (worst %s m)" % U.expo(worst, 1), worst < 1e-6)
	for i in 3: main.animate(1.0 / 60.0)
	check("drawn as Perseverance, the stage that lowered it gone", f.rover_model != null and f.rover_model.group.name == "Perseverance"
		and not f.craft.group.visible)
	_fly_ingenuity(f)
	f.teardown()

# Ingenuity off Perseverance: set down, up 8 m on the site's own air, ahead for ten seconds, and down again on
# the drawn ground, its feet on the triangles.
func _fly_ingenuity(f: Spaceflight) -> void:
	check("Ingenuity comes off Perseverance", f.can_deploy_heli() and f.deploy_heli())
	if f.heli == null: return
	var h: Rotorcraft = f.heli
	f.rover_keys = false
	var feet := func() -> float:
		var worst := 0.0
		for leg: Vector3 in h.spec.legs:
			var p := DQuat.rotate(DVec3.from_v3(leg), h.q).add_in(h.pos)
			worst = maxf(worst, absf(p.y - h.ground.height(-p.x, p.z)))
		return worst
	var run := func(s: float) -> void:
		for i in int(s / 0.05): main.step_flight(0.05)
	main.set_drawn(false)
	run.call(2.0)
	check("it stands on the drawn ground (feet within %s m of the triangles)" % U.fixed(feet.call(), 4), h.on_ground and feet.call() < 0.01)
	h.cmd_climb = 1.0
	run.call(4.0)
	h.cmd_climb = 0.0
	run.call(4.0)
	var up := h.height_above_ground()
	h.cmd_fwd = 1.0
	run.call(10.0)
	var v := Vector2(h.vel.x, h.vel.z).length()
	h.cmd_fwd = 0.0
	run.call(6.0)
	h.cmd_climb = -1.0
	run.call(12.0)
	h.cmd_climb = 0.0
	run.call(3.0)
	main.set_drawn(true)
	check("it flew: %s m up, %s m/s ahead, %s W at the battery (air %s kg/m³)" % [U.fixed(up, 1), U.fixed(v, 1), U.fixed(h.power_w, 0), U.fixed(h.rho, 4)],
		up > 4.0 and v > 6.0 and not h.crashed)
	check("it came down on the drawn ground (feet within %s m)" % U.fixed(feet.call(), 4), h.on_ground and not h.crashed and feet.call() < 0.01)
	for i in 3: main.animate(1.0 / 60.0)
	check("drawn as Ingenuity", f.heli_model != null and f.heli_model.group.name == "Ingenuity")

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
