extends SceneTree

# PAD CHECK. See README.md for verification usage.
#   Godot --headless --path . --script res://tools/padcheck.gd [-- padmodels=0]

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else ""
	LaunchSite.use_authored_pads = str(args.get("padmodels", "1")) != "0"
	var authored_craft: bool = str(args.get("assets", "1")) != "0"
	var worst_all := 0.0
	var failed := false
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
			var obstruction := MeshInstance3D.new()
			obstruction.name = "intrusion_probe"
			var mesh := BoxMesh.new()
			mesh.size = Vector3.ONE * 0.1
			obstruction.mesh = mesh
			obstruction.position.y = 20.0
			site.group.add_child(obstruction)
		site.update({"released": false, "throttle": 0.0, "dt": 100.0})
		var skin: LaunchSite.Envelope = site.skin
		var hits := {}
		var worst := 0.0
		var samples := [0]
		_walk(site.group, site.group.global_transform.affine_inverse(), skin, hits, samples)
		for k in hits: worst = maxf(worst, hits[k])
		worst_all = maxf(worst_all, worst)
		print("padcheck: %-9s pad=%-10s authored=%s craft=%s  fit %d ms  %d samples near the stack  %d parts intrude, worst %.2f m" %
			[key, site.style, LaunchSite.use_authored_pads, craft.authored, fit_ms, samples[0], hits.size(), worst])
		for k in hits:
			if hits[k] > 0.05: print("    %-40s %.2f m" % [k, hits[k]])
		site.group.free()
		craft.group.free()
	print("padcheck: worst intrusion %.2f m" % worst_all)
	CraftAssets.clear()
	failed = failed or worst_all > 0.0
	print("PADCHECK DONE ", "FAIL" if failed else "PASS")
	quit(1 if failed else 0)

func _walk(n: Node, inv: Transform3D, skin, hits: Dictionary, samples: Array) -> void:
	if n is Node3D and not (n as Node3D).visible: return
	if n is MeshInstance3D and n.name != "deluge" and (n as MeshInstance3D).mesh != null:
		var mi := n as MeshInstance3D
		if mi.material_override is ShaderMaterial and n.get_parent() != null and n.get_parent().name == "launch_site":
			pass
		var xf := inv * mi.global_transform
		var mesh := mi.mesh
		for s in mesh.get_surface_count():
			if mesh is ArrayMesh and mesh.surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES: continue
			if mesh is PointMesh: continue
			var arr := mesh.surface_get_arrays(s)
			var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var ix = arr[Mesh.ARRAY_INDEX]
			var indexed: bool = ix != null and ix.size() > 0
			var count: int = ix.size() if indexed else v.size()
			for t in range(0, count, 3):
				var a: Vector3 = xf * v[ix[t] if indexed else t]
				var b: Vector3 = xf * v[ix[t + 1] if indexed else t + 1]
				var c: Vector3 = xf * v[ix[t + 2] if indexed else t + 2]
				for p in [a, b, c, (a + b) * 0.5, (b + c) * 0.5, (c + a) * 0.5, (a + b + c) / 3.0]:
					var r := Vector2(p.x, p.z).length()
					if r > skin.radius_in(p.y - 0.1, p.y + 0.1): continue
					samples[0] += 1
					var depth := _enclosed(skin, p)
					if depth > 0.02:
						var key := _label(mi)
						hits[key] = maxf(hits.get(key, 0.0), depth)
	for c in n.get_children(): _walk(c, inv, skin, hits, samples)

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
