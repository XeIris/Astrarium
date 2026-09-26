extends SceneTree
# Native kernel vs the GDScript reference loop, preset by preset:
# identical sub-step counts, positions to rounding, and the time each takes.
#   Godot --headless --path . --script res://tools/nbodycheck.gd
func build(key: String) -> Array:
	var seq := [0]
	Presets.rand_override = func(): seq[0] += 1; return fposmod(float(seq[0]) * 0.6180339887, 1.0)
	var p: Dictionary = Presets.PRESETS[key]
	var out := []
	var id := 1
	for spec in p.build.call():
		var b := Derive.new_body(id, spec); id += 1
		b.contact_au = Derive.contact_au(b, spec, Derive.render_radius(b, spec, b.mass0, float(p.sceneScale), float(p.get("bodyScale", 1.0)), bool(p.get("trueScale", false))), float(p.sceneScale))
		out.append(b)
	Presets.rand_override = Callable()
	return out

func run(bodies: Array, p: Dictionary, frames: int, native: bool) -> Dictionary:
	var sim_dt := float(p.get("timeScale", 2.0)) / 60.0
	var steps := 0
	var merges := [0]
	var on_merger := func(ev): merges[0] += 1; bodies.erase(ev.absorbed)
	var t0 := Time.get_ticks_usec()
	for f in frames:
		var r: Dictionary
		if native: r = NBody.step_physics(bodies, sim_dt, float(p.get("maxStep", 5e-3)), float(p.get("gwBoost", 0.0)), on_merger)
		else: r = Derive.step_physics(bodies, sim_dt, float(p.get("maxStep", 5e-3)), float(p.get("gwBoost", 0.0)), on_merger)
		steps += r.steps
	return {"us": Time.get_ticks_usec() - t0, "steps": steps, "merges": merges[0]}

func _init() -> void:
	print("native kernel loaded: ", NBody.native_available())
	var frames := int(OS.get_environment("FRAMES")) if OS.get_environment("FRAMES") != "" else 240
	for key in (OS.get_environment("KEYS").split(",") if OS.get_environment("KEYS") != "" else ["solar", "alphacen", "trisolaris", "stellar_zoo", "bhmerger", "nsmerger", "sirius", "feeding", "threebody"]):
		var p: Dictionary = Presets.PRESETS[key]
		var a := build(key); var b := build(key)
		var ra := run(a, p, frames, false)
		var rb := run(b, p, frames, true)
		var maxd := 0.0
		for i in mini(a.size(), b.size()):
			var s := maxf(a[i].pos.length(), 1e-12)
			maxd = maxf(maxd, a[i].pos.distance_to(b[i].pos) / s)
		print("%-12s gd %7.2f ms/frame  native %6.3f ms/frame  (x%5.0f)  steps %d/%d  merges %d/%d  bodies %d/%d  max rel dpos %s" % [
			key, ra.us / 1000.0 / frames, rb.us / 1000.0 / frames, float(ra.us) / maxf(rb.us, 1.0),
			ra.steps, rb.steps, ra.merges, rb.merges, a.size(), b.size(), U.expo(maxd, 2)])
	quit()
