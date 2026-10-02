extends SceneTree
# Native equivalence needs the extension loaded, not its GDScript fallback.
# Godot --headless --path . --script res://tools/nbodycheck.gd

const REL_TOL := 1e-11
const ABS_TOL := 1e-13

func build(key: String) -> Array:
	var seq := [0]
	Presets.rand_override = func(): seq[0] += 1; return fposmod(float(seq[0]) * 0.6180339887, 1.0)
	var p: Dictionary = Presets.PRESETS[key]
	var out := []
	var id := 1
	for spec in p.build.call():
		var b := Derive.new_body(id, spec)
		id += 1
		b.contact_au = Derive.contact_au(b, spec, Derive.render_radius(b, spec, b.mass0, float(p.sceneScale), float(p.get("bodyScale", 1.0)), bool(p.get("trueScale", false))), float(p.sceneScale))
		out.append(b)
	Presets.rand_override = Callable()
	return out

func near(a: float, b: float) -> bool:
	return is_finite(a) and is_finite(b) and absf(a - b) <= ABS_TOL + REL_TOL * maxf(absf(a), absf(b))

func compare(a: Array, b: Array) -> String:
	if a.size() != b.size(): return "body counts %d/%d" % [a.size(), b.size()]
	for i in a.size():
		var x: Body = a[i]
		var y: Body = b[i]
		if x.id != y.id or x.type != y.type or x.alive != y.alive:
			return "body identity/state differs at index %d" % i
		if not near(x.mass, y.mass): return "mass differs for body %d" % x.id
		for axis in ["x", "y", "z"]:
			if not near(x.pos.get(axis), y.pos.get(axis)): return "position.%s differs or is nonfinite for body %d" % [axis, x.id]
			if not near(x.vel.get(axis), y.vel.get(axis)): return "velocity.%s differs or is nonfinite for body %d" % [axis, x.id]
	return ""

func check(key: String, frames: int) -> bool:
	var p: Dictionary = Presets.PRESETS[key]
	var a := build(key)
	var b := build(key)
	var sim_dt := float(p.get("timeScale", 2.0)) / 60.0
	var gd_us := 0
	var native_us := 0
	var steps := 0
	var merges := 0
	for f in frames:
		var gd_events := []
		var native_events := []
		var gd_merger := func(ev):
			gd_events.append([ev.survivor.id, ev.absorbed.id])
			Derive.refresh_structure(ev.survivor)
			a.erase(ev.absorbed)
		var native_merger := func(ev):
			native_events.append([ev.survivor.id, ev.absorbed.id])
			Derive.refresh_structure(ev.survivor)
			b.erase(ev.absorbed)
		var t0 := Time.get_ticks_usec()
		var ra := Derive.step_physics(a, sim_dt, float(p.get("maxStep", 5e-3)), float(p.get("gwBoost", 0.0)), gd_merger)
		gd_us += Time.get_ticks_usec() - t0
		t0 = Time.get_ticks_usec()
		var rb := NBody.step_physics(b, sim_dt, float(p.get("maxStep", 5e-3)), float(p.get("gwBoost", 0.0)), native_merger)
		native_us += Time.get_ticks_usec() - t0
		var problem := compare(a, b)
		if ra.steps != rb.steps: problem = "sub-step counts %d/%d" % [ra.steps, rb.steps]
		if not near(ra.stepped, rb.stepped): problem = "integrated time differs or is nonfinite"
		if gd_events != native_events: problem = "merger identities/order differ"
		if not problem.is_empty():
			printerr("NBODYCHECK FAIL %s frame %d: %s" % [key, f + 1, problem])
			return false
		steps += ra.steps
		merges += gd_events.size()
	print("NBODYCHECK PASS %-12s gd %.3f ms/frame native %.3f ms/frame steps %d merges %d bodies %d" % [
		key, gd_us / 1000.0 / frames, native_us / 1000.0 / frames, steps, merges, a.size()])
	return true

func _init() -> void:
	if not NBody.native_available():
		printerr("NBODYCHECK FAIL: native extension unavailable; equivalence cannot be checked")
		quit(1)
		return
	var frame_arg := OS.get_environment("FRAMES")
	var frames := int(frame_arg) if frame_arg != "" else 240
	var keys: PackedStringArray = OS.get_environment("KEYS").split(",", false) if OS.get_environment("KEYS") != "" else PackedStringArray(["solar", "alphacen", "trisolaris", "stellar_zoo", "bhmerger", "nsmerger", "sirius", "feeding", "threebody"])
	if frames <= 0 or (frame_arg != "" and not frame_arg.is_valid_int()) or keys.is_empty():
		printerr("NBODYCHECK FAIL: FRAMES must be positive and KEYS nonempty")
		quit(1)
		return
	for key in keys:
		if not Presets.PRESETS.has(key):
			printerr("NBODYCHECK FAIL: unknown preset ", key)
			quit(1)
			return
	var failed := 0
	for key in keys:
		if not check(key, frames): failed += 1
	print("NBODYCHECK DONE %d presets, %d failed (abs tolerance %s, relative tolerance %s)" % [keys.size(), failed, ABS_TOL, REL_TOL])
	quit(1 if failed > 0 else 0)
