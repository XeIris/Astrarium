extends SceneTree

# PAD CHECK. See README.md for verification usage.
#   Godot --headless --path . --script res://tools/padcheck.gd [-- padmodels=0]
#     [assets=0] [inject_intrusion=1] [inject_fixed_arm=1] [inject_late_arm=1]
#
# Three tests per launcher, each failing with a nonzero exit:
#   rest     nothing of the complex is inside the vehicle standing on the pad
#   count    through the terminal count and liftoff, no moving arm touches the vehicle
#            as it rises: each arm on its own schedule, the vehicle flown through the
#            same count by Vessel (ignition against the hold-downs at its lead, solids
#            at release) and its rise taken RISE_MARGIN times faster
#   ascent   with every arm retracted, nothing stands in the vehicle's swept column:
#            its skin carried straight up, widened by DRIFT once it has risen
#            DRIFT_RISE (drift grows with the climb; at the deck it is nil)

const COUNT := 10.0          # spaceflight.start_count's terminal count
const STEP := 0.1
const DRIFT := 0.5           # lateral drift allowance while clearing the tower, m
const DRIFT_RISE := 10.0
const EPS := 0.05
## How much faster than flown the test vehicle rises: thrust and mass dispersions.
const RISE_MARGIN := 1.5

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else ""
	LaunchSite.use_authored_pads = str(args.get("padmodels", "1")) != "0"
	var authored_craft: bool = str(args.get("assets", "1")) != "0"
	var failed := false
	var worst_all := 0.0
	for key in ["saturnv", "shuttle", "falcon9", "starship"]:
		if authored_craft: CraftAssets.craft_models_ready([key])
		if CraftAssets.VALIDATION_ERRORS.has(key):
			printerr("PADCHECK invalid craft ", key, ": ", CraftAssets.VALIDATION_ERRORS[key])
			failed = true
		var veh: Dictionary = Vehicles.VEHICLES[key]
		var craft := CraftModel.build_craft(veh)
		root.add_child(craft.group)
		var t0 := Time.get_ticks_msec()
		var site := LaunchSite.create_launch_site(veh, craft.height, null, craft.group)
		var fit_ms := Time.get_ticks_msec() - t0
		root.add_child(site.group)
		if args.get("inject_intrusion", "0") == "1" and key == "saturnv":
			var probe := MeshInstance3D.new()
			probe.name = "intrusion_probe"
			var mesh := BoxMesh.new()
			mesh.size = Vector3.ONE * 0.1
			probe.mesh = mesh
			probe.position.y = 20.0
			site.group.add_child(probe)
		if args.get("inject_fixed_arm", "0") == "1" and key == "saturnv":
			# A fixed boom over the nose, as the LUT's crane jib once was.
			var jib := LaunchSite.truss(30.0, 2.0, 2.0)
			jib.name = "fixed_boom_probe"
			jib.position = Vector3(-25.0, craft.height + 8.0, 0.0)
			site.group.add_child(jib)
		if args.get("inject_late_arm", "0") == "1" and key == "saturnv":
			# Every arm waits until 3 s after release, as a lagging retraction would.
			for arm in site.arms: arm.at = -3.0
		var skin: LaunchSite.Envelope = site.skin
		var inv := site.group.global_transform.affine_inverse()

		# rest
		site.update({"t_minus": INF, "throttle": 0.0, "dt": 100.0})
		var hits := {}
		var samples := [0]
		_walk(site.group, inv, skin, hits, samples)
		var worst := 0.0
		for k in hits: worst = maxf(worst, hits[k])

		# the count and liftoff
		var rise_at := _flown_rise(key, veh)
		var moving := _arm_points(site, inv)
		var count_hits := {}
		var t := -COUNT
		var all_open := false
		while not all_open and t < 30.0:
			t += STEP
			site.update({"t_minus": -t, "throttle": 0.0, "dt": STEP})
			var rise: float = RISE_MARGIN * rise_at.call(t)
			all_open = t > 0.0
			for arm in site.arms:
				if float(arm.p) < 1.0: all_open = false
			for m in moving:
				var arm: Dictionary = m.arm
				# A parked arm before release was covered by the rest test, unless an arm
				# that carries it is moving.
				if t <= 0.0 and (m.carriers as Array).all(func(c): return float(c.p) <= 0.0 or float(c.p) >= 1.0): continue
				var xf: Transform3D = inv * (arm.group as Node3D).global_transform
				for p0 in m.pts:
					var p: Vector3 = xf * (p0 as Vector3) - Vector3(0.0, rise, 0.0)
					if Vector2(p.x, p.z).length() > skin.radius_in(p.y - 0.1, p.y + 0.1): continue
					var depth := _enclosed(skin, p)
					if depth > 0.02:
						var k: String = "%s at T%+.1f s" % [str(arm.group.name), t]
						var label := str(arm.group.name)
						if depth > count_hits.get(label, [0.0])[0]: count_hits[label] = [depth, k]

		# the ascent column, everything retracted
		skin.build_sweep(DRIFT)
		var ascent_hits := {}
		_walk_ascent(site.group, inv, skin, ascent_hits)

		var n_fail := hits.size() + count_hits.size() + ascent_hits.size()
		print("padcheck: %-9s pad=%-10s authored=%s craft=%s  fit %d ms  %d samples near the stack  rest %d (worst %.2f m)  count %d  ascent %d" %
			[key, site.style, LaunchSite.use_authored_pads, craft.authored, fit_ms, samples[0], hits.size(), worst,
			count_hits.size(), ascent_hits.size()])
		for k in hits:
			if hits[k] > 0.05: print("    rest    %-40s %.2f m" % [k, hits[k]])
		for k in count_hits: print("    count   %-40s %.2f m deep, %s" % [k, count_hits[k][0], count_hits[k][1]])
		for k in ascent_hits: print("    ascent  %s, %.2f m into the column" % [ascent_hits[k][1], ascent_hits[k][0]])
		worst_all = maxf(worst_all, worst)
		failed = failed or n_fail > 0
		site.group.free()
		craft.group.free()
	print("padcheck: worst rest intrusion %.2f m" % worst_all)
	CraftAssets.clear()
	print("PADCHECK DONE ", "FAIL" if failed else "PASS")
	quit(1 if failed else 0)

## The vehicle's height above the pad t seconds after release, flown by Vessel
## through spaceflight's count: engines lit against the hold-downs IGNITION_LEAD
## before release (solids wait for it), then free.
func _flown_rise(key: String, veh: Dictionary) -> Callable:
	var earth := Body.new()
	earth.name = "Earth"; earth.type = "planet"
	earth.mass = 3.003e-6; earth.radius = 6371.0e3 / Rocketry.AU_M
	earth.alive = true
	var ship := Vessel.new({"vehicle": veh, "parent": earth, "bodies": [earth]})
	ship.vehicle_key = key
	ship.place_on_pad()
	ship.held_down = true
	var lead: float = Spaceflight.IGNITION_LEAD.get(key, 4.0)
	var t := -COUNT
	var h := PackedFloat32Array()
	while t < 30.0 - 1e-6:
		if t >= -lead - 1e-6: ship.throttle = 1.0
		if t >= -1e-6: ship.held_down = false
		ship.step(STEP)
		t += STEP
		if t > 1e-6: h.append(maxf(ship.altitude(), 0.0))
	return func(tt: float) -> float:
		if tt <= 0.0 or h.is_empty(): return 0.0
		var i := clampi(int(round(tt / STEP)) - 1, 0, h.size() - 1)
		return h[i]

## Every vertex (and triangle centroid) of each moving arm, in the arm's own frame.
## An arm that carries another (the GOX vent arm and its hood) leaves the inner one
## out: it has its own entry, which follows both motions.
func _arm_points(site: LaunchSite, inv: Transform3D) -> Array:
	var out := []
	var groups := {}
	for arm in site.arms: groups[arm.group] = true
	for arm in site.arms:
		var grp: Node3D = arm.group
		var to_arm := (inv * grp.global_transform).affine_inverse()
		var pts := PackedVector3Array()
		_collect(grp, inv, to_arm, pts, groups)
		# itself and every arm it rides on
		var carriers := []
		for other in site.arms:
			if other.group == grp or (other.group as Node).is_ancestor_of(grp): carriers.append(other)
		out.append({"arm": arm, "pts": pts, "carriers": carriers})
	return out

func _collect(n: Node, inv: Transform3D, to_arm: Transform3D, pts: PackedVector3Array, skip := {}) -> void:
	if n is Node3D and not (n as Node3D).visible: return
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		var xf := to_arm * inv * (n as MeshInstance3D).global_transform
		var mesh := (n as MeshInstance3D).mesh
		for s in mesh.get_surface_count():
			if mesh is ArrayMesh and mesh.surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES: continue
			var arr := mesh.surface_get_arrays(s)
			var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var ix = arr[Mesh.ARRAY_INDEX]
			var indexed: bool = ix != null and ix.size() > 0
			var count: int = ix.size() if indexed else v.size()
			for p in v: pts.append(xf * p)
			for t in range(0, count, 3):
				var a: Vector3 = v[ix[t] if indexed else t]
				var b: Vector3 = v[ix[t + 1] if indexed else t + 1]
				var c: Vector3 = v[ix[t + 2] if indexed else t + 2]
				pts.append(xf * ((a + b + c) / 3.0))
	for c in n.get_children():
		if not skip.has(c): _collect(c, inv, to_arm, pts, skip)

## Triangle sample points of every visible mesh, in the site's frame, to `fn`.
func _each_point(n: Node, inv: Transform3D, fn: Callable) -> void:
	if n is Node3D and not (n as Node3D).visible: return
	if n is MeshInstance3D and n.name != "deluge" and (n as MeshInstance3D).mesh != null:
		var mi := n as MeshInstance3D
		var xf := inv * mi.global_transform
		var mesh := mi.mesh
		for s in mesh.get_surface_count():
			var prim: int = mesh.surface_get_primitive_type(s) if mesh is ArrayMesh else Mesh.PRIMITIVE_TRIANGLES
			var arr := mesh.surface_get_arrays(s)
			var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			# Wires (a lightning catenary) are lines, sampled every half metre.
			if prim == Mesh.PRIMITIVE_LINES or prim == Mesh.PRIMITIVE_LINE_STRIP:
				var step := 2 if prim == Mesh.PRIMITIVE_LINES else 1
				for i in range(0, v.size() - 1, step):
					var p0: Vector3 = xf * v[i]; var p1: Vector3 = xf * v[i + 1]
					var segs := maxi(1, int(p0.distance_to(p1) / 0.5))
					for k in segs + 1: fn.call(mi, p0.lerp(p1, float(k) / segs))
				continue
			if prim != Mesh.PRIMITIVE_TRIANGLES: continue
			var ix = arr[Mesh.ARRAY_INDEX]
			var indexed: bool = ix != null and ix.size() > 0
			var count: int = ix.size() if indexed else v.size()
			for t in range(0, count, 3):
				var a: Vector3 = xf * v[ix[t] if indexed else t]
				var b: Vector3 = xf * v[ix[t + 1] if indexed else t + 1]
				var c: Vector3 = xf * v[ix[t + 2] if indexed else t + 2]
				for p in [a, b, c, (a + b) * 0.5, (b + c) * 0.5, (c + a) * 0.5, (a + b + c) / 3.0]:
					fn.call(mi, p)
	for c in n.get_children(): _each_point(c, inv, fn)

func _walk(n: Node, inv: Transform3D, skin, hits: Dictionary, samples: Array) -> void:
	_each_point(n, inv, func(mi: MeshInstance3D, p: Vector3) -> void:
		if Vector2(p.x, p.z).length() > skin.radius_in(p.y - 0.1, p.y + 0.1): return
		samples[0] += 1
		var depth := _enclosed(skin, p)
		if depth > 0.02:
			var key := _label(mi)
			hits[key] = maxf(hits.get(key, 0.0), depth))

func _walk_ascent(n: Node, inv: Transform3D, skin, hits: Dictionary) -> void:
	_each_point(n, inv, func(mi: MeshInstance3D, p: Vector3) -> void:
		var over := maxf(p.y - skin.swept_floor(p.x, p.z, false) - EPS,
			p.y - skin.swept_floor(p.x, p.z, true) - DRIFT_RISE)
		if over > 0.0:
			var key := _label(mi) + " near " + str((p * 10.0).round() / 10.0)
			var mesh_key := _label(mi)
			if over > hits.get(mesh_key, [0.0])[0]: hits[mesh_key] = [over, key])

## How far `p` would have to move to get out of the vehicle — 0 if a
## horizontal ray escapes in any of eight directions.
func _enclosed(skin, p: Vector3) -> float:
	var out := INF
	for k in 8:
		var az := float(k) * TAU / 8.0
		var u := Vector2(cos(az), sin(az))
		var along := p.x * u.x + p.z * u.y
		var across := -p.x * u.y + p.z * u.x
		var s: float = skin.standoff(p.y - 0.1, p.y + 0.1, across - 0.1, across + 0.1, az)
		if s <= along: return 0.0
		out = minf(out, s - along)
	return out

## A readable name: the node and its nearest named ancestors.
func _label(n: Node) -> String:
	var parts: Array[String] = []
	var c := n
	while c != null and c.name != "launch_site":
		var nm := str(c.name)
		if not nm.begins_with("@"): parts.push_front(nm)
		c = c.get_parent()
	var mi := n as MeshInstance3D
	var mat := mi.material_override if mi.material_override != null else mi.mesh.surface_get_material(0)
	return "/".join(parts) + " [" + (str(mat.resource_name) if mat != null else "?") + " @%s]" % str(mi.global_position.round())
