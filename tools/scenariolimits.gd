extends Node

# Measures what ScenarioFile.COST predicts: frame time by body count and type, with and
# without a tight pair, and the integrator alone. Prints numbers; it is not a check.
# Windowed (frame times need rendering), VSync off, 1280×720 at render scale 1:
#   mode=sweep mix=rocky|worlds|giants|stars|compact|mixed counts=32,64,128
#   mode=tight mix=… seps=0.2,0.02 counts=…   a 1+1 M☉ pair far out sets everyone's sub-step
#   mode=phys counts=…                         NBody.step_physics alone, ms per sub-step
var stage: Node
var mode := "sweep"
var mix := "mixed"
var counts := [32, 64, 128, 192, 256]
var frames := 60
var seps := [0.2, 0.02]

const MIXES := {
	"stars": ["star"], "rocky": ["planet"], "worlds": ["world"], "giants": ["gas-giant"],
	"compact": ["white-dwarf", "neutron", "bh"],
	"mixed": ["planet", "gas-giant", "star", "world", "white-dwarf", "neutron", "bh"],
}
const MASS := {"star": 0.3, "planet": 3e-6, "world": 3e-6, "gas-giant": 9.5e-4, "white-dwarf": 0.6, "neutron": 1.4, "bh": 5.0}

func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		var kv := arg.split("=", true, 1)
		match kv[0]:
			"mode": mode = kv[1]
			"mix": mix = kv[1]
			"counts": counts = Array(kv[1].split(",")).map(func(s): return int(s))
			"frames": frames = int(kv[1])
			"seps": seps = Array(kv[1].split(",")).map(func(s): return float(s))
	if mode == "phys":
		phys()
		get_tree().quit(0)
		return
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	stage = load("res://main.tscn").instantiate()
	stage._cmd["settings"] = "default"
	add_child(stage)
	await get_tree().process_frame
	stage.set_process(false)
	stage._start("sandbox")
	stage.lessons.store = ""
	if DisplayServer.get_name() != "headless":
		stage.pipe.set_render_scale(1.0)
		stage.pipe.set_view_size(Vector2i(1280, 720))
	if mode == "sweep": await sweep()
	elif mode == "tight": await tight()
	get_tree().quit(0)

# Circular orbits about a 50 M☉ hole from 3 to 60 AU, so close passes rarely shorten the step.
func ring_system(n: int) -> Array:
	var Mc := 50.0
	var out := [{"type": "bh", "name": "Centre", "mass": Mc, "pos": [0.0, 0.0, 0.0], "vel": [0.0, 0.0, 0.0]}]
	var types: Array = MIXES[mix]
	for i in n:
		var a: float = 3.0 + 57.0 * float(i) / maxf(1.0, float(n - 1))
		var ang := float(i) * 2.399963
		var v := sqrt(Physics.G * Mc / a)
		var type: String = types[i % types.size()]
		out.append({"type": type, "name": "%s %d" % [type, i], "mass": MASS[type],
			"pos": [cos(ang) * a, 0.02 * a * sin(float(i)), sin(ang) * a], "vel": [-sin(ang) * v, 0.0, cos(ang) * v]})
	return out

func preset(bodies: Array) -> Dictionary:
	return {"name": "limits", "sceneScale": 1.0, "bodyScale": 1.0, "camRadius": 90.0,
		"lensing": false, "mesh": false, "timeScale": 0.5, "maxStep": 2e-3,
		"build": func() -> Array: return bodies}

func measure(label: String) -> Dictionary:
	for i in 20:
		stage.animate(1.0 / 60.0)
		await RenderingServer.frame_post_draw
	var wall := []; var cpu := []; var steps := []
	var prev := Time.get_ticks_usec()
	for i in frames:
		var t0 := Time.get_ticks_usec()
		stage.animate(1.0 / 60.0)
		cpu.append(float(Time.get_ticks_usec() - t0) / 1000.0)
		steps.append(stage.state.last_steps)
		await RenderingServer.frame_post_draw
		var now := Time.get_ticks_usec()
		wall.append(float(now - prev) / 1000.0)
		prev = now
	wall.sort(); cpu.sort(); steps.sort()
	var r := {"label": label, "alive": stage.state.bodies.size(), "wall_ms": wall[wall.size() / 2],
		"cpu_ms": cpu[cpu.size() / 2], "steps": steps[steps.size() / 2], "fps": 1000.0 / wall[wall.size() / 2]}
	print("LIMITS ", JSON.stringify(r))
	return r

func sweep() -> void:
	for n in counts:
		var t0 := Time.get_ticks_usec()
		if not stage.load_preset_spec("limits", preset(ring_system(n))): continue
		print("LIMITS load n=%d ms=%.1f" % [n, float(Time.get_ticks_usec() - t0) / 1000.0])
		var r: Dictionary = await measure("%s n=%d" % [mix, n])
		if r.wall_ms > 250.0: break

func tight() -> void:
	for sep in seps:
		for n in counts:
			var bodies := ring_system(n)
			var M := 2.0
			var rel := Presets.kepler(M, sep, 0.0, 0.0, 0.0)
			var vc := sqrt(Physics.G * 50.0 / 80.0)
			for k in [-0.5, 0.5]:
				bodies.append({"type": "star", "name": "Pair %s" % k, "mass": 1.0,
					"pos": Presets.addv([80.0, 0.0, 0.0], rel.pos, k), "vel": Presets.addv([0.0, 0.0, vc], rel.vel, k)})
			if not stage.load_preset_spec("limits", preset(bodies)): continue
			var r: Dictionary = await measure("sep=%s %s n=%d" % [sep, mix, n])
			if r.wall_ms > 250.0: break

func phys() -> void:
	for n in counts:
		var bodies := []
		for spec in ring_system(n): bodies.append(Derive.new_body(bodies.size() + 1, spec))
		var t0 := Time.get_ticks_usec()
		var r := NBody.step_physics(bodies, 0.05, 1e-4, 0.0)
		var ms := float(Time.get_ticks_usec() - t0) / 1000.0
		print("LIMITS ", JSON.stringify({"phys_n": n, "native": NBody.native_available(), "steps": r.steps, "ms_per_step": ms / maxf(1.0, float(r.steps))}))
