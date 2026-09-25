extends SceneTree

# ===========================================================================
# BEHAVIOUR SMOKE TEST for Craft.update() / separate() — the parts that move.
#   Godot --headless --path godot --script res://tools/crafttest.smoke.gd [-- assets=0]
# Prints PASS/FAIL lines; exit code 1 on any failure.
# ===========================================================================

const CM := preload("res://sim/flight/craftmodel.gd")
var fails := 0

func check(what: String, ok: bool, detail := "") -> void:
	print(("PASS " if ok else "FAIL ") + what + ("" if detail == "" else "  (" + detail + ")"))
	if not ok: fails += 1

func _init() -> void:
	var assets := not OS.get_cmdline_user_args().has("assets=0")
	if assets: CraftAssets.craft_models_ready()
	var st0 := {"dt": 0.0, "attached": {}, "deploy": {}, "gimbal": {"x": 0.25, "z": 0.0}, "flap": 1.0}

	# gimbal clamp: Merlins 5°, S-IC centre F-1 `_fixed`, Hail Mary drives rigid
	var f9 = CM.build_craft(CM.vehicle("falcon9"))
	f9.update(st0)
	var p: Node3D = f9.stages[0].parts.gimbals[1]
	check("falcon9 Merlin clamps to 5°", is_equal_approx(p.rotation.z, -deg_to_rad(5.0)), str(rad_to_deg(p.rotation.z)))
	var sv = CM.build_craft(CM.vehicle("saturnv"))
	sv.update(st0)
	var names := []
	for q: Node3D in sv.stages[0].parts.gimbals: names.append("%s:%.2f" % [q.name, rad_to_deg(q.rotation.z)])
	if assets:
		check("S-IC centre F-1 is _fixed and does not swing", names[0].begins_with("gimbal_sic_0_fixed:0.00") or names[0].ends_with(":0.00") or names[0].ends_with(":-0.00"), ", ".join(names))
	var hm = CM.build_craft(CM.vehicle("hailmary"))
	hm.update(st0)
	var moved := 0
	for q: Node3D in hm.stages[0].parts.gimbals:
		if absf(q.rotation.z) > 1e-6 or absf(q.rotation.x) > 1e-6: moved += 1
	check("hailmary: 4 drives, none swings", hm.stages[0].parts.gimbals.size() == 4 and moved == 0)

	# deploy easing: 0.55 per second
	var dep := {"dt": 1.0, "attached": {}, "deploy": {"f9s1": 1.0}, "gimbal": {}, "flap": 0.0}
	f9.update(dep)
	check("falcon9 legs ease at 0.55/s", is_equal_approx(f9.stages[0].deploy, 0.55), str(f9.stages[0].deploy))
	var leg: Node3D = f9.stages[0].parts.legs[0]
	check("leg hinge rotation.z = -1.15·d", is_equal_approx(leg.rotation.z, -0.55 * 1.15), str(leg.rotation.z))
	check("4 legs, 4 fins, 2 arrays, 2 halves", f9.stages[0].parts.legs.size() == 4 and f9.stages[0].parts.fins.size() == 4
		and f9.stages[3].parts.arrays.size() == 2 and f9.stages[2].parts.halves.size() == 2)
	# arrays stowed at exactly 90°
	var arr: Node3D = f9.stages[3].parts.arrays[0]
	check("stowed array folds to 90°", is_equal_approx(arr.rotation.z, PI / 2.0), str(arr.rotation.z))

	# separation: drifts, tumbles, disappears after 6 s
	f9.separate("f9s1", 4.0, 0.3)
	var s1 = f9.stage("f9s1")
	f9.update({"dt": 1.0, "attached": {"f9s1": false}})
	check("separated stage drifts down 4 m/s", is_equal_approx(s1.group.position.y, s1.base_y - 4.0), str(s1.group.position.y))
	check("separated stage still visible while drifting", s1.group.visible)
	for i in 6: f9.update({"dt": 1.0, "attached": {"f9s1": false}})
	check("separated stage hidden after 6 s", not s1.group.visible and s1.sep == null)
	f9.update({"dt": 1.0, "attached": {"f9s1": false}})
	check("detached stage stays hidden", not s1.group.visible)

	# the LM gear is NOT a deployable; the shuttle's SSMEs belong to the orbiter
	var lm = CM.build_craft(CM.vehicle("lm"))
	check("LM has no parts.legs", lm.stages[0].parts.legs.is_empty())
	var sh = CM.build_craft(CM.vehicle("shuttle"))
	check("ET draws no bells (engineOn)", sh.stage("et").parts.gimbals.is_empty() and sh.stage("orbiter").parts.gimbals.size() == 3)
	check("craft.height is measured", absf(sh.height - 57.1) < 0.1, str(sh.height))
	check("authored flag", f9.authored == assets)

	for c in [f9, sv, hm, lm, sh]: c.group.free()
	CraftAssets.clear()
	print("smoke: %d failure(s)" % fails)
	quit(1 if fails > 0 else 0)
