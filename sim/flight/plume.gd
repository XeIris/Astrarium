class_name Plume
extends RefCounted

# Pressure-dependent plume shape and propellant-dependent colour.
# The local pass has no temperature channel: emitters add RGB with zero coverage,
# smoke covers with blend_mix. Transparent order comes from LocalView.ORDER.

const ORDER_SMOKE := 10
const ORDER_FLAME := 20

# Flame temperature and appearance per propellant. Chamber temperatures are the
# real ones; what is drawn is the plume, which is cooler.
const PROPELLANT := {
	"kerolox":    { "T": 3400.0, "core": [1.00, 0.72, 0.34], "edge": [1.00, 0.36, 0.08], "soot": 0.85, "glow": 1.0 },
	"hydrolox":   { "T": 3200.0, "core": [0.72, 0.80, 1.00], "edge": [0.42, 0.36, 0.95], "soot": 0.06, "glow": 0.34 },
	"methalox":   { "T": 3500.0, "core": [0.62, 0.80, 1.00], "edge": [1.00, 0.55, 0.22], "soot": 0.30, "glow": 0.75 },
	"solid":      { "T": 3000.0, "core": [1.00, 0.90, 0.70], "edge": [1.00, 0.55, 0.20], "soot": 1.00, "glow": 1.35 },
	"hypergolic": { "T": 3050.0, "core": [1.00, 0.94, 0.72], "edge": [0.95, 0.72, 0.35], "soot": 0.18, "glow": 0.55 },
	# Not thermal at all: a beam of ions recombining, so it gets a low nominal
	# temperature and is dominated by line emission rather than a continuum.
	"ion":        { "T": 1200.0, "core": [0.55, 0.62, 1.00], "edge": [0.40, 0.20, 0.95], "soot": 0.0, "glow": 0.25, "beam": true },
	# The spin drive radiates at 25.98 µm; what's drawn is its faint visible tail.
	"spin":       { "T": 1500.0, "core": [1.00, 0.30, 0.18], "edge": [0.55, 0.06, 0.04], "soot": 0.0, "glow": 0.45, "beam": true },
}

# Emission per unit path in HDR, integrated along the ray by plume.gdshader:
#   kerolox     soot-luminous yellow-white core, orange afterburning layer, red
#               and brown-black smoke
#   hydrolox    nearly invisible in daylight: shock cells and a faint OH violet
#   methalox    blue CH/C₂ core, pink-orange fringe, little soot
#   solid       white-yellow alumina torch inside its own white cloud
#   hypergolic  pale peach, near-invisible in vacuum
#   ion         collimated xenon: dim, blue, steady
#   spin        a deep red haze on the axis (the drive is far infrared)
const LOOK := {
	"kerolox":    {"core": [1.40, 1.09, 0.63], "shock": [1.0, 0.92, 0.75], "mix": [1.0, 0.42, 0.10],
		"tail": [0.55, 0.14, 0.03], "smoke": [0.030, 0.024, 0.018], "afterburn": 1.0, "soot": 0.55,
		"coreLen": 4.0, "diamonds": 0.8, "machDisk": 0.15, "bright": 3.2},
	"hydrolox":   {"core": [0.16, 0.20, 0.36], "shock": [1.25, 1.05, 0.85], "mix": [0.09, 0.055, 0.12],
		"tail": [0.025, 0.015, 0.04], "smoke": [0.0, 0.0, 0.0], "afterburn": 0.4, "soot": 0.0,
		"coreLen": 5.0, "diamonds": 1.2, "machDisk": 0.8, "bright": 1.4},
	"methalox":   {"core": [0.40, 0.62, 1.00], "shock": [0.95, 1.0, 1.1], "mix": [1.0, 0.46, 0.26],
		"tail": [0.45, 0.13, 0.06], "smoke": [0.004, 0.004, 0.004], "afterburn": 0.9, "soot": 0.06,
		"coreLen": 4.5, "diamonds": 1.2, "machDisk": 0.35, "bright": 2.4},
	"solid":      {"core": [3.0, 2.8, 2.4], "shock": [1.0, 0.95, 0.85], "mix": [2.0, 1.44, 0.76],
		"tail": [1.2, 0.66, 0.26], "smoke": [0.60, 0.58, 0.55], "afterburn": 1.4, "soot": 0.85,
		"coreLen": 3.0, "diamonds": 0.35, "machDisk": 0.0, "bright": 2.6},
	"hypergolic": {"core": [0.60, 0.49, 0.37], "shock": [0.6, 0.54, 0.48], "mix": [0.35, 0.19, 0.12],
		"tail": [0.12, 0.045, 0.022], "smoke": [0.0, 0.0, 0.0], "afterburn": 0.35, "soot": 0.0,
		"coreLen": 4.0, "diamonds": 0.6, "machDisk": 0.2, "bright": 1.4},
	"ion":        {"core": [0.21, 0.30, 0.60], "shock": [0, 0, 0], "mix": [0, 0, 0], "tail": [0, 0, 0],
		"smoke": [0, 0, 0], "afterburn": 0.0, "soot": 0.0, "coreLen": 99.0, "diamonds": 0.0,
		"machDisk": 0.0, "bright": 1.0, "beam": true},
	"spin":       {"core": [0.55, 0.10, 0.05], "shock": [0, 0, 0], "mix": [0, 0, 0], "tail": [0, 0, 0],
		"smoke": [0, 0, 0], "afterburn": 0.0, "soot": 0.0, "coreLen": 99.0, "diamonds": 0.0,
		"machDisk": 0.0, "bright": 1.0, "beam": true},
}

# Per-engine look. Published exit pressure and Mach against ambient give the
# pressure ratio the shape comes from: a Merlin (p_e ≈ 0.6 atm) shows soft diamonds
# at the pad, an RS-25 (≈ 0.16 atm) hangs a white Mach disk under each bell.
#   F-1   gas-generator exhaust film-cools the extension: a dark fuel-rich sleeve
#         that ignites raggedly downstream (`film`)
#   RSRM  alumina: white soot (LOOK.solid)
const ENGINE_LOOK := {
	"F-1": {"pe": 41000.0, "mach": 3.2, "film": 1.0, "soot": 0.95, "diamonds": 0.45, "coreLen": 3.0},
	"J-2": {"pe": 3000.0, "mach": 4.4},
	"Merlin 1D": {"pe": 60000.0, "mach": 3.5, "soot": 0.6},
	"Merlin 1D Vacuum": {"pe": 1000.0, "mach": 4.6, "soot": 0.12, "brightK": 0.7},
	"RS-25 (SSME)": {"pe": 16000.0, "mach": 4.4, "machDisk": 1.2, "diamonds": 1.4},
	"RSRM solid booster": {"pe": 62000.0, "mach": 3.0},
	"Raptor 2": {"pe": 70000.0, "mach": 3.6},
	"Raptor Vacuum": {"pe": 800.0, "mach": 4.8, "brightK": 0.8},
	"LM Descent Engine": {"pe": 1500.0, "mach": 4.2},
	"LM Ascent Engine": {"pe": 1500.0, "mach": 4.0},
	"Service Propulsion System": {"pe": 900.0, "mach": 4.6},
	"Mars Descent Engine (MLE)": {"pe": 5000.0, "mach": 3.8},
	"Draco RCS": {"pe": 1000.0, "mach": 4.0},
}

## Local light level relative to full sun at Earth (set by spaceflight.gd); smoke is
## only as bright as the light on it.
static var daylight := 1.0
## Dynamic pressure of the air the vehicle is flying through, Pa (spaceflight.gd).
static var freestream_q := 0.0
## Raymarch steps scale with the rendering preset (1 at High).
static var detail := 1.0
## The exhaust smoke's reflectance: grey soot from kerosene, white alumina from a
## solid, near-white condensation from hydrogen.
static func smoke_grey(prop: Dictionary) -> float:
	if prop == PROPELLANT.solid: return 0.72
	return lerpf(0.72, 0.42, clampf(float(prop.soot), 0.0, 1.0))

## Smoke drawn as raymarched volumes (High and Ultra) rather than sprites, and the
## march it takes: [steps, light steps].
static var smoke_volume := false
static var smoke_steps := [5, 0]
## Pad-cloud puffs a second at full power (fewer on High, where overdraw is the cost).
static var smoke_rate := 26.0
## Toward the sun in the local frame, and the deflected exhaust's glow 0..1
## (spaceflight.gd), for the volume smoke.
static var sun_local := Vector3.UP
static var fire_level := 0.0

static var _sh := {}
static func shader(name: String) -> Shader:
	if not _sh.has(name):
		_sh[name] = load("res://shaders/flight/%s.gdshader" % name)
	return _sh[name]

static func _v3(a: Array) -> Vector3:
	return Vector3(a[0], a[1], a[2])

static func _prop(name) -> Dictionary:
	return PROPELLANT.get(name, PROPELLANT.kerolox) if name != null else PROPELLANT.kerolox

## A closed unit cylinder, y from −1 to 0: the plume's bounding volume. Only back
## faces are drawn, so it covers every reachable pixel, inside or out.
static var _box: ArrayMesh = null
static func _box_mesh() -> ArrayMesh:
	if _box != null: return _box
	var g := CraftModel.Geo.new()
	var n := 24
	for ring in 2:
		var y := -float(ring)
		for i in n:
			var th := float(i) / n * TAU
			g.pos.append(Vector3(cos(th), y, sin(th))); g.nrm.append(Vector3(cos(th), 0.0, sin(th)))
	for i in n:
		var a := i; var b2 := (i + 1) % n; var c := n + i; var d := n + (i + 1) % n
		# Outward-facing; the shader culls front faces, so the far wall is drawn.
		g.idx.append_array([a, b2, c, b2, d, c])
	# caps
	var top := g.pos.size(); g.pos.append(Vector3(0, 0, 0)); g.nrm.append(Vector3.UP)
	var bot := g.pos.size(); g.pos.append(Vector3(0, -1, 0)); g.nrm.append(Vector3.DOWN)
	for i in n:
		g.idx.append_array([top, (i + 1) % n, i])
		g.idx.append_array([bot, n + i, n + (i + 1) % n])
	_box = CraftModel._to_mesh(g, null)
	return _box

static var _quad: QuadMesh = null
static func quad() -> QuadMesh:
	if _quad == null:
		_quad = QuadMesh.new()
		_quad.size = Vector2(1, 1)
	return _quad

static var _sprite_mats := {}
## One material per (blend, kind): every sprite shares it and carries its own
## colour, opacity and rotation (sprite.gdshaderinc).
static func sprite_material(additive: bool, kind: int, priority: int) -> ShaderMaterial:
	var k := "%s:%d:%d" % [additive, kind, priority]
	if not _sprite_mats.has(k):
		var m := ShaderMaterial.new()
		m.shader = shader("sprite_add" if additive else "sprite_mix")
		m.set_shader_parameter("uKind", kind)
		if kind == 2: m.set_shader_parameter("uMap", smoke_texture())
		m.render_priority = priority
		_sprite_mats[k] = m
	return _sprite_mats[k]

## A lone sprite: a quad MeshInstance3D whose instance uniforms are its tint,
## opacity and rotation. Godot merges consecutive ones into one draw.
static func make_sprite(mat: ShaderMaterial) -> MeshInstance3D:
	var s := MeshInstance3D.new()
	s.mesh = quad()
	s.material_override = mat
	s.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# The quad turns to face the camera in the vertex shader, so its own AABB
	# (a flat square in XY) is not where it draws; the margin covers the turn.
	s.extra_cull_margin = 1.0
	s.set_instance_shader_parameter("opacity", 0.0)
	return s

## A set of sprites drawn in one call, in instance order. Instance colour is
## (tint, opacity) and custom.x the rotation (sprite.gdshaderinc).
class Sprites extends RefCounted:
	var node := MultiMeshInstance3D.new()
	var mm := MultiMesh.new()
	## 20 floats per instance: a 3×4 transform, the colour, the custom data.
	var buf := PackedFloat32Array()

	func _init(mat: ShaderMaterial, count: int) -> void:
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.use_custom_data = true
		mm.mesh = Plume.quad()
		mm.instance_count = count
		mm.visible_instance_count = 0
		node.visible = false
		buf.resize(count * 20)
		node.multimesh = mm
		node.material_override = mat
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# The quad turns to face the camera in the vertex shader, so its own AABB
		# (a flat square in XY) is not where it draws; the margin covers the turn.
		node.extra_cull_margin = 1.0

	## Instance i: a sprite of size `s` at `p`. `extra` fills custom.yzw (the volume
	## smoke's sun transmittance, fire light and seed).
	func put(i: int, p: Vector3, s: float, tint: Color, opacity: float, rot: float, extra := Vector3.ZERO) -> void:
		var o := i * 20
		buf[o] = s; buf[o + 1] = 0.0; buf[o + 2] = 0.0; buf[o + 3] = p.x
		buf[o + 4] = 0.0; buf[o + 5] = s; buf[o + 6] = 0.0; buf[o + 7] = p.y
		buf[o + 8] = 0.0; buf[o + 9] = 0.0; buf[o + 10] = s; buf[o + 11] = p.z
		buf[o + 12] = tint.r; buf[o + 13] = tint.g; buf[o + 14] = tint.b; buf[o + 15] = opacity
		buf[o + 16] = rot; buf[o + 17] = extra.x; buf[o + 18] = extra.y; buf[o + 19] = extra.z

	## Draw the first n instances as put().
	func commit(n: int) -> void:
		mm.buffer = buf
		mm.visible_instance_count = n
		# an empty MultiMesh still costs a draw call
		node.visible = n > 0

# ONE ENGINE'S PLUME
class PlumeFx extends RefCounted:
	var mesh: Node3D               # the group hung on the gimbal pivot
	var jet: MeshInstance3D
	var glow: MeshInstance3D
	var material: ShaderMaterial
	var propellant: Dictionary
	var look: Dictionary
	## The jet's built length, reported (the pad flame goes out on it).
	var reach: float
	var exit_d: float
	var pe := 50000.0              # exit pressure, Pa
	var stage_key := ""
	var engine = null
	var beam := false
	## The flame's light on its surroundings — the vehicle's base, the deck,
	## the smoke — one per stage, on the plume that leads it. Null on the rest.
	var light: OmniLight3D = null
	var light_scale := 1.0
	## Vacuum thrust this plume carries at full throttle, N (a merged far field: all of it).
	var thrust := 0.0
	var steps := 26
	## One engine of a merged cluster: the far field balloons for all of them.
	var near := false
	var temp_code := 0.32
	## Last update's box length and smoke-column radius, m (where the trail picks up).
	var last_len := 0.0
	var trail_r := 0.0
	var trail_k := 0.0

	## @param throttle 0..1 @param pa ambient pressure, Pa @param p0 reference (sea level)
	func update(throttle: float, pa: float, time: float, _p0: float = 101325.0) -> void:
		var on := throttle > 0.001
		mesh.visible = on
		if light != null: light.visible = on
		if not on: return
		var pr := pe / maxf(pa, 1e-3)
		# Away from the pad the plume expands until its pressure meets what pushes on it,
		# the ambient air plus the freestream's dynamic pressure (docs/physics/plumes.md).
		var push := pa + Plume.freestream_q
		var r_eq := sqrt(thrust * throttle / (PI * 2.5 * maxf(push, 1.0))) if thrust > 0.0 else 0.0
		var balloon := maxf(r_eq / (exit_d * 0.5), 1.0)
		var hi := 0.0 if (beam or near) else U.smooth(balloon, 2.5, 6.0)
		# Shock heating where the freestream meets the boundary; none in vacuum.
		var shell_k := sqrt(clampf(push / 4000.0, 0.0, 1.0))
		material.set_shader_parameter("uBalloon", balloon)
		material.set_shader_parameter("uHi", hi)
		material.set_shader_parameter("uShellK", shell_k)
		material.set_shader_parameter("uSteps", int(roundf(steps * (1.0 + hi * 0.6) * Plume.detail)))
		material.set_shader_parameter("uThrottle", throttle)
		material.set_shader_parameter("uPR", pr)
		material.set_shader_parameter("uTime", time)
		var sm: Vector3 = Plume._v3(look.smoke) * Plume.daylight
		material.set_shader_parameter("uSmoke", sm)
		# The bounding cylinder follows the jet: a pencil at the pad, a wide bell in vacuum,
		# shorter when throttled.
		var under := clampf(log(maxf(pr, 1.0)) / log(300.0), 0.0, 1.0)
		var re := exit_d * 0.5
		var L := reach * (1.0 + 1.3 * under) * (0.55 + 0.45 * throttle)
		if beam: L = reach
		var lx := L / exit_d
		var rj := 1.0 + under * 2.6 * pow(lx, 0.62) + maxf(0.14 * (1.0 - under), 0.05) * lx
		if beam: rj = 1.0 + 0.03 * lx
		var R := re * rj * 1.9
		# The ballooned plume: widest a little downstream, trailing several widths.
		L = maxf(L, r_eq * 6.5 * hi)
		R = maxf(R, r_eq * 1.45 * hi)
		# In air the afterburning burns out within about a vehicle length and the rest
		# is smoke: soot, plus condensing water in the humid lower air.
		var air := clampf(pow(pa / 101325.0, 0.25), 0.0, 1.0) if not beam else 0.0
		var flame_len := exit_d * (8.0 + 30.0 * under)
		var trail_k := 0.0 if near else clampf(float(propellant.soot) + 0.3, 0.0, 1.2) * air * (1.0 - hi)
		if trail_k > 0.0:
			L = maxf(L, flame_len * 2.2)
			R = maxf(R, re * rj * 2.6)
		var grey := Plume.smoke_grey(propellant)
		material.set_shader_parameter("uFlame", clampf(flame_len / L, 0.2, 1.0) if trail_k > 0.0 else 1.0)
		material.set_shader_parameter("uTrailK", trail_k)
		# The shader scales everything by its calibration; the smoke's light is a reflectance.
		material.set_shader_parameter("uTrail", Vector3(grey, grey * 0.985, grey * 0.96) * Plume.daylight / (temp_code * 2.4))
		material.set_shader_parameter("uBox", Vector3(R, L, R))
		last_len = L
		trail_r = re * rj * 1.6
		self.trail_k = trail_k
		jet.custom_aabb = AABB(Vector3(-R * 1.1, -L * 1.05, -R * 1.1), Vector3(R * 2.2, L * 1.05 + 1.0, R * 2.2))
		# Exit glow a little inside the exit plane, growing with the plume.
		if glow != null:
			glow.position.y = -exit_d * 0.08
			var s := exit_d * (1.6 + 2.4 * under) * (0.6 + 0.4 * throttle) * (0.35 if beam else 1.0)
			glow.scale = Vector3(s, s, s)
			# Inside a ballooned plume the exit is a source seen through its own fire.
			glow.set_instance_shader_parameter("opacity", (0.18 if beam else 0.75) * float(propellant.glow) * (0.45 + 0.55 * throttle) * (1.0 - 0.95 * hi))
		if light != null:
			light.light_energy = light_scale * throttle * (0.4 if beam else 1.0)

## One engine's plume, scaled by `exit_d` and driven per frame. `engine` is the
## vehicles.gd entry; `role` is "single", "near" (one engine of a merged cluster) or
## "far" (the merged far field).
static func create_plume(propellant, exit_d: float, length_scale: float = 18.0,
		engine = null, role: String = "single", seed: float = 0.0) -> PlumeFx:
	var P := _prop(propellant)
	var look: Dictionary = (LOOK.get(propellant, LOOK.kerolox) as Dictionary).duplicate()
	var name := str(engine.get("name", "")) if engine is Dictionary else ""
	var over: Dictionary = ENGINE_LOOK.get(name, {})
	for k in over: look[k] = over[k]
	if role == "far":
		# a merged far field is turbulent flow with no nozzle of its own: its
		# shock cells and its core belong to the single jets upstream
		look.diamonds = 0.0; look.machDisk = 0.0; look.film = 0.0; look.coreLen = 0.6
	var beam: bool = look.get("beam", false)
	var L := exit_d * length_scale * (2.4 if beam else 1.0)
	var fx := PlumeFx.new()
	fx.propellant = P
	fx.look = look
	fx.beam = beam
	fx.reach = L
	fx.exit_d = exit_d
	fx.pe = float(look.get("pe", 1000.0 if beam else 50000.0))
	fx.thrust = float(engine.get("thrustVac", 0.0)) if engine is Dictionary else 0.0
	var m := ShaderMaterial.new()
	m.shader = shader("plume")
	m.set_shader_parameter("uRe", exit_d * 0.5)
	m.set_shader_parameter("uMach", float(look.get("mach", 3.6)))
	m.set_shader_parameter("uSeed", seed * 13.7)
	m.set_shader_parameter("uCore", _v3(look.core))
	m.set_shader_parameter("uShock", _v3(look.shock))
	m.set_shader_parameter("uMix", _v3(look.mix))
	m.set_shader_parameter("uTail", _v3(look.tail))
	m.set_shader_parameter("uCoreLen", float(look.coreLen))
	m.set_shader_parameter("uBright", float(look.bright) * float(look.get("brightK", 1.0)))
	m.set_shader_parameter("uDiamonds", float(look.diamonds))
	m.set_shader_parameter("uMachDisk", float(look.machDisk))
	m.set_shader_parameter("uAfterburn", float(look.afterburn))
	m.set_shader_parameter("uSoot", float(look.soot))
	m.set_shader_parameter("uFilm", float(look.get("film", 0.0)))
	m.set_shader_parameter("uBeam", 1.0 if beam else 0.0)
	m.set_shader_parameter("uNear", 1.0 if role == "near" else 0.0)
	m.set_shader_parameter("uFar", 1.0 if role == "far" else 0.0)
	fx.temp_code = clampf(log(maxf(float(P.T), 2.0)) / 25.33, 0.006, 0.984)
	m.set_shader_parameter("uTempCode", fx.temp_code)
	# a cluster's single engines only draw their first few diameters
	fx.steps = 14 if role == "near" else (22 if role == "far" else 26)
	fx.near = role == "near"
	m.set_shader_parameter("uSteps", fx.steps)
	m.render_priority = ORDER_FLAME
	fx.material = m
	var jet := MeshInstance3D.new()
	jet.mesh = _box_mesh()
	jet.material_override = m
	jet.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# the vertex shader scales the unit box to the jet, up to ~50 exit radii
	# across in vacuum: never cull it on the unit box's own bounds
	jet.custom_aabb = AABB(Vector3(-L * 3.0, -L * 2.5, -L * 3.0), Vector3(L * 6.0, L * 2.6, L * 6.0))
	fx.jet = jet
	if role == "near":
		fx.reach = exit_d * 6.0

	var g := Node3D.new()
	g.name = "plume"
	g.add_child(jet)
	# The nozzle exit is a light source (not for a merged far field).
	if role != "far":
		var glow := make_sprite(sprite_material(true, 0, ORDER_FLAME))
		# color.setRGB(...) — floats, so NOT colour-converted
		glow.set_instance_shader_parameter("tint", Vector3(
			minf(1.0, P.core[0] * 1.1 + 0.25), minf(1.0, P.core[1] * 1.1 + 0.2), minf(1.0, P.core[2] * 1.1 + 0.15)))
		g.add_child(glow)
		fx.glow = glow
	g.visible = false
	fx.mesh = g
	return fx

## The light a plume's flame throws: the mixing layer's colour, a few dozen exit
## diameters of reach.
static func add_flame_light(fx: PlumeFx, scale_d: float) -> void:
	var l := OmniLight3D.new()
	l.name = "flame_light"
	var c: Vector3 = _v3(fx.look.mix) + _v3(fx.look.core) * 0.3
	var mx := maxf(c.x, maxf(c.y, c.z))
	l.light_color = Color(c.x / mx, c.y / mx, c.z / mx) if mx > 0.0 else Color(1, 0.6, 0.3)
	l.omni_range = maxf(scale_d * 22.0, 40.0)
	l.omni_attenuation = 1.6
	l.light_specular = 0.35
	l.shadow_enabled = false
	l.position = Vector3(0.0, -scale_d * 1.5, 0.0)
	fx.light_scale = clampf(scale_d * 1.6, 1.5, 18.0) * float(fx.look.bright) * \
		(0.25 if fx.propellant == PROPELLANT.hydrolox else 1.0)
	l.visible = false
	fx.mesh.add_child(l)
	fx.light = l

# RCS — short, cold, translucent puffs. They matter because they are the only
# visible sign that the vehicle is holding attitude.
class RCSPuffs extends RefCounted:
	var group: Node3D
	var sprites: Plume.Sprites
	var tint := U.lin(0xbfd8ff)
	var pos := PackedVector3Array()
	var dir := PackedVector3Array()
	var life := PackedFloat64Array()
	var size := PackedFloat64Array()
	var next := 0

	## Fire a puff at a local position, in a local direction.
	func fire(p: Vector3, d: Vector3, s: float = 1.0) -> void:
		next = (next + 1) % life.size()
		pos[next] = p + d * (s * 0.6)
		life[next] = 1.0; dir[next] = d; size[next] = s

	func update(dt: float) -> void:
		var n := 0
		for i in life.size():
			if life[i] <= 0.0: continue
			life[i] -= dt * 4.5
			if life[i] <= 0.0: continue
			var k: float = size[i] * (1.0 + (1.0 - life[i]) * 2.2)
			pos[i] += dir[i] * (dt * size[i] * 4.0)
			sprites.put(n, pos[i], k, tint, life[i] * 0.55, 0.0)
			n += 1
		if n > 0 or sprites.mm.visible_instance_count > 0: sprites.commit(n)

static func create_rcs_puffs(count: int = 12) -> RCSPuffs:
	var o := RCSPuffs.new()
	o.group = Node3D.new()
	o.group.name = "rcs"
	o.sprites = Sprites.new(sprite_material(true, 1, ORDER_FLAME), count)
	o.group.add_child(o.sprites.node)
	o.pos.resize(count); o.dir.resize(count); o.life.resize(count); o.size.resize(count)
	o.size.fill(1.0)
	return o

# RE-ENTRY PLASMA: a bow-shock cap whose brightness and colour follow the
# Sutton–Graves heat flux, the same number that loads the shield.
class EntryGlow extends RefCounted:
	var mesh: MeshInstance3D
	var material: ShaderMaterial

	## @param q W/m² from Rocketry.heat_flux
	func update(q: float, time: float) -> void:
		# 1 MW/m² is a hard entry; scale so a shallow one is a visible glow and a
		# lunar return is blinding.
		var h := clampf(q / 1.1e6, 0.0, 2.5)
		mesh.visible = h > 0.004
		material.set_shader_parameter("uHeat", h)
		material.set_shader_parameter("uTime", time)
		# Shock-layer temperature from the flux, so it re-images correctly in IR.
		material.set_shader_parameter("uTemp", clampf(1400.0 + q * 0.006, 900.0, 12000.0))

static func create_entry_glow(radius: float) -> EntryGlow:
	var o := EntryGlow.new()
	var m := ShaderMaterial.new()
	m.shader = shader("entry_glow")
	m.render_priority = ORDER_FLAME
	o.material = m
	var mi := MeshInstance3D.new()
	mi.rotation_order = EULER_ORDER_XYZ
	mi.mesh = CraftModel._to_mesh(CraftModel._sphere(radius, 28, 18, 0.0, TAU, 0.0, PI * 0.62), m)
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.visible = false
	o.mesh = mi
	return o

# LAUNCH SMOKE: the pad cloud thrown out of the flame trench, and the exhaust
# trail laid along the climb. Both are fixed to the ground and air, not to the
# vehicle: spaceflight.gd re-expresses them in the moving local frame each frame
# (reframe). Drawn as sprites, or on High and Ultra as raymarched volumes.
class SmokeColumn extends RefCounted:
	const PAD_N := 620
	const TRAIL_N := 300
	const VENT_N := 100
	const N := PAD_N + TRAIL_N + VENT_N
	const STEAM_KIND := 0
	const SOOT_KIND := 1
	const TRAIL_KIND := 2
	const VENT_KIND := 3
	var group: Node3D
	## The live puffs, back to front, split where the deluge sorts: `far` draws
	## before it and `near` after, as each puff would if it were its own object.
	var far: Plume.Sprites
	var near: Plume.Sprites
	var pos := PackedVector3Array()
	var vel := PackedVector3Array()
	var life := PackedFloat64Array()
	var rate := PackedFloat64Array()
	var spin := PackedFloat64Array()
	var rot := PackedFloat64Array()
	var size0 := PackedFloat64Array()
	var size := PackedFloat64Array()
	var age := PackedFloat64Array()
	## Turbulent diffusion: the puff's width goes as √(1 + grow·age).
	var grow := PackedFloat64Array()
	var op0 := PackedFloat64Array()
	var color := PackedColorArray()
	var kind := PackedByteArray()
	var seed := PackedFloat64Array()
	## Transmittance toward the sun through the rest of the cloud, smoothed. Refreshed a
	## slice per frame from a sample of the other puffs (an all-pairs sum would cost
	## more than the drawing).
	var shade := PackedFloat64Array()
	var _shade_at := 0
	var _pad_next := 0
	var _trail_next := PAD_N
	var _vent_next := PAD_N + TRAIL_N
	var _pad_acc := 0.0
	## Where the deflected exhaust burns, in the group's frame.
	var fire_pos := Vector3.ZERO
	## The wind the smoke drifts with, m/s in the local frame.
	var wind := Vector3.ZERO
	## Where the last trail puff was laid, in the group's frame (reframed with them).
	var trail_last := Vector3.INF
	var _depth := PackedFloat64Array()
	var _keys := PackedInt64Array()
	# White steam from the deluge (most of the pad cloud's volume, condensing out
	# fastest) and soot or alumina from the exhaust (what is left a minute later).
	var STEAM := U.lin(0xe8eaec)
	var SOOT := U.lin(0x4a423a)
	## Soot as a volume scatters many times; its effective albedo is ~0.2, not black.
	var SOOT_VOLUME := U.lin(0xa09281)

	func _slot_pad() -> int:
		_pad_next = (_pad_next + 1) % PAD_N
		return _pad_next

	func _slot_trail() -> int:
		_trail_next = PAD_N + (_trail_next - PAD_N + 1) % TRAIL_N
		return _trail_next

	func _spawn(i: int, p: Vector3, v: Vector3, s: float, c: Color, k: int, r: float, g: float, op: float) -> void:
		pos[i] = p; vel[i] = v; size0[i] = s; size[i] = s; age[i] = 0.0
		color[i] = c; kind[i] = k; rate[i] = r; grow[i] = g; op0[i] = op
		life[i] = 1.0
		rot[i] = randf() * TAU
		# Rolling, because a puff that holds its orientation while it grows reads as
		# a decal rather than a turbulent lump.
		spin[i] = (randf() - 0.5) * 0.4
		seed[i] = randf() * 17.0
		shade[i] = 1.0

	## The pad cloud. `axis` is the flame trench (zero for an open deflector, which
	## throws it every way); `spread` is the plume's scale, m; `power` the thrust fraction.
	func emit(origin: Vector3, power: float, spread: float, dt: float, soot: float = 0.7, axis := Vector3.ZERO) -> void:
		# Many small eddies that grow into each other (smoke_rate a second at full
		# power), each living ~15 s within its share of the buffer.
		_pad_acc += power * Plume.smoke_rate * dt
		while _pad_acc >= 1.0:
			_pad_acc -= 1.0
			var i := _slot_pad()
			var trench := axis.length_squared() > 0.0 and randf() < 0.8
			var d: Vector3
			var p: Vector3
			if trench:
				# Out of either end of the trench, already far from the vehicle, at speed.
				var side := 1.0 if randf() < 0.5 else -1.0
				var lat := axis.cross(Vector3.UP).normalized()
				d = (axis * side + lat * (randf() - 0.5) * 0.5).normalized()
				p = origin + d * spread * (0.8 + randf() * 2.2) + Vector3(0.0, randf() * spread * 0.3, 0.0)
			else:
				var a := randf() * TAU
				d = Vector3(cos(a), 0.0, sin(a))
				p = origin + d * spread * (0.3 + randf() * 0.9) + Vector3(0.0, randf() * spread * 0.2, 0.0)
			# It rolls OUTWARD first and only then rises: the deflected exhaust leaves at
			# the speed of sound.
			var v := d * spread * (1.2 + randf() * 1.6) + Vector3(0.0, spread * 0.3 * randf(), 0.0)
			var is_soot := randf() < soot * (0.75 if trench else 0.45)
			var c: Color = (SOOT_VOLUME if Plume.smoke_volume else SOOT) if is_soot else STEAM
			# No two puffs the same value, or several hundred read as one flat sheet.
			var k2 := 0.82 + randf() * 0.3
			c = Color(c.r * k2, c.g * k2, c.b * k2)
			# Soot survives; steam condenses out. The difference leaves a dark column
			# standing after the white has gone.
			_spawn(i, p, v, spread * (0.32 + randf() * 0.45), c, SOOT_KIND if is_soot else STEAM_KIND,
				0.05 if is_soot else 0.06, 2.4, 0.62 if is_soot else 0.5)

	## One trail puff where the flame ends: `p` in the group's frame, moving at `v`.
	func emit_trail(p: Vector3, v: Vector3, s: float, opacity: float, tint: Color) -> void:
		var i := _slot_trail()
		var k2 := 0.9 + randf() * 0.15
		# Ragged: sizes and offsets vary, so overlapping puffs read as a column of
		# billows rather than a tube.
		_spawn(i, p + Vector3(randf() - 0.5, randf() - 0.5, randf() - 0.5) * s * 0.5, v,
			s * (0.6 + randf() * 0.7), Color(tint.r * k2, tint.g * k2, tint.b * k2), TRAIL_KIND,
			1.0 / (70.0 + randf() * 40.0), 0.35, opacity)

	## Boil-off from a tank vent: cold, so it sinks as it spreads and soon evaporates.
	func emit_vent(p: Vector3, v: Vector3, s: float, opacity: float) -> void:
		_vent_next = PAD_N + TRAIL_N + (_vent_next - PAD_N - TRAIL_N + 1) % VENT_N
		var k2 := 0.95 + randf() * 0.08
		_spawn(_vent_next, p, v, s, Color(STEAM.r * k2, STEAM.g * k2, STEAM.b * k2), VENT_KIND,
			1.0 / (2.5 + randf() * 1.5), 14.0, opacity)

	## The frame moved: positions and velocities through the affine map `A·x + t`.
	func reframe(A: Basis, t: Vector3) -> void:
		for i in N:
			if life[i] <= 0.0: continue
			pos[i] = A * pos[i] + t
			vel[i] = A * vel[i]
		if trail_last != Vector3.INF: trail_last = A * trail_last + t

	func update(dt: float) -> void:
		if dt <= 0.0: return
		if Plume.smoke_volume: _shade_slice(PAD_N / 10)
		for i in N:
			if life[i] <= 0.0: continue
			life[i] -= dt * rate[i]
			if life[i] <= 0.0: continue
			age[i] += dt
			pos[i] += vel[i] * dt
			var v := vel[i]
			if kind[i] == TRAIL_KIND:
				# Left behind in still air: it slows to the wind and spreads.
				v += (wind - v) * minf(dt * 0.6, 1.0)
			elif kind[i] == VENT_KIND:
				# Colder and denser than the air: it slumps down the vehicle as it drifts.
				v += (wind * 0.6 - v) * minf(dt * 0.8, 1.0) + Vector3(0.0, -1.4 * dt, 0.0)
			else:
				var hv := Vector3(v.x, 0.0, v.z)
				hv += (Vector3(wind.x, 0.0, wind.z) - hv) * minf(dt * 0.45, 1.0)
				# Hot, so it rises; drag holds it to a few metres a second.
				v = Vector3(hv.x, v.y + dt * (2.4 - v.y * 0.5), hv.z)
			vel[i] = v
			size[i] = size0[i] * sqrt(1.0 + grow[i] * age[i])
			rot[i] += spin[i] * dt
			# Entrained air dilutes the soot, so a puff pales as it ages: the dark core
			# is dark because it is young.
			if kind[i] == SOOT_KIND: color[i] = color[i].lerp(STEAM, dt * 0.04)

	## Sun transmittance for `n` pad puffs, estimated from 40 others each and scaled up.
	func _shade_slice(n: int) -> void:
		var sun := Plume.sun_local.normalized()
		for k in n:
			var i := _shade_at
			_shade_at = (_shade_at + 1) % PAD_N
			if life[i] <= 0.0: continue
			var od := 0.0
			var tried := 0
			for m in 40:
				var j := randi() % PAD_N
				if j == i or life[j] <= 0.0: continue
				tried += 1
				var d := pos[j] - pos[i]
				var along := d.dot(sun)
				if along <= 0.0: continue
				var r := size[j] * 0.5
				var perp2 := (d - sun * along).length_squared()
				if perp2 >= r * r: continue
				od += sqrt(1.0 - perp2 / (r * r)) * pow(life[j], 1.4) * op0[j] * 1.6
			if tried > 0: od *= float(PAD_N) / 40.0
			shade[i] = lerpf(shade[i], exp(-od), 0.35)

	## Order the live puffs back to front for `camera`. `deluge` is the launch
	## site's steam, the one other object in this render_priority.
	func draw(camera: Camera3D, deluge: GeometryInstance3D) -> void:
		var xf := group.global_transform
		var eye := camera.global_position
		var fwd := -camera.global_basis.z
		_keys.clear()
		for i in N:
			if life[i] <= 0.0: continue
			_depth[i] = fwd.dot(xf * pos[i] - eye)
			if _depth[i] < -size[i]: continue
			# depth to 1/1024 m, then the slot: one native sort, farthest first
			_keys.append(int(floor(-_depth[i] * 1024.0)) * 1024 + i)
		_keys.sort()
		var split := -INF
		if deluge != null and deluge.is_visible_in_tree():
			split = fwd.dot(deluge.global_transform * deluge.custom_aabb.get_center() - eye)
		var nf := 0; var nn := 0
		for key in _keys:
			var i := key & 1023
			# A new puff condenses in over half a second rather than appearing whole.
			var op := pow(life[i], 1.4) * op0[i] * minf(age[i] * 2.0, 1.0)
			# Nearly gone: not worth a raymarch.
			if op < 0.05: continue
			# The fire lights the low, near puffs from underneath.
			var fd := (pos[i] - fire_pos).length() / maxf(size[i], 1.0)
			var ex := Vector3(shade[i] if kind[i] != TRAIL_KIND else 0.92, Plume.fire_level * exp(-fd * 0.7), seed[i])
			if _depth[i] > split:
				far.put(nf, pos[i], size[i], color[i], op, rot[i], ex); nf += 1
			else:
				near.put(nn, pos[i], size[i], color[i], op, rot[i], ex); nn += 1
		if nf > 0 or far.mm.visible_instance_count > 0: far.commit(nf)
		if nn > 0 or near.mm.visible_instance_count > 0: near.commit(nn)
		# Sorted by origin (sorting_use_aabb_center off): the depth Godot sorts
		# on is near-plane distance − sorting_offset, so these put each set just
		# either side of the deluge.
		if is_finite(split):
			var d0 := fwd.dot(xf.origin - eye)
			var eps := maxf(absf(split), absf(d0)) * 1.0e-4 + 1.0e-3
			far.node.sorting_offset = d0 - split - eps
			near.node.sorting_offset = d0 - split + eps

	func clear() -> void:
		life.fill(0.0)
		_pad_acc = 0.0
		trail_last = Vector3.INF
		far.commit(0)
		near.commit(0)

static func create_smoke_column() -> SmokeColumn:
	var o := SmokeColumn.new()
	var n := SmokeColumn.N
	assert(n <= 1024)    # the sort key's slot bits
	o.group = Node3D.new()
	o.group.name = "smoke"
	var mat := sprite_material(false, 2, ORDER_SMOKE)
	o.far = Sprites.new(mat, n)
	o.near = Sprites.new(mat, n)
	for sp in [o.far, o.near]:
		sp.node.sorting_use_aabb_center = false
		o.group.add_child(sp.node)
	# Packed arrays are values: resizing them through a list would resize copies.
	o.pos.resize(n); o.vel.resize(n); o.life.resize(n); o.rate.resize(n)
	o.spin.resize(n); o.rot.resize(n); o.size0.resize(n); o.size.resize(n); o.age.resize(n)
	o.grow.resize(n); o.op0.resize(n); o.color.resize(n); o.kind.resize(n)
	o.seed.resize(n); o.shade.resize(n); o._depth.resize(n)
	o.shade.fill(1.0)
	return o

## The shared material for volumetric smoke; spaceflight.gd sets its light.
static var _volume_mat: ShaderMaterial = null
static func smoke_volume_material(noise: Texture3D) -> ShaderMaterial:
	if _volume_mat == null:
		_volume_mat = ShaderMaterial.new()
		_volume_mat.shader = shader("smoke_volume")
		_volume_mat.render_priority = ORDER_SMOKE
	if noise != null: _volume_mat.set_shader_parameter("uNoise", noise)
	_volume_mat.set_shader_parameter("uSteps", int(smoke_steps[0]))
	_volume_mat.set_shader_parameter("uLightSteps", int(smoke_steps[1]))
	_volume_mat.set_shader_parameter("uFine", smoke_steps[0] > 6)
	return _volume_mat

## Draw `column` as volumes (with this noise) or as sprites.
static func set_smoke_volume(column: SmokeColumn, on: bool, noise: Texture3D) -> void:
	smoke_volume = on and noise != null
	var mat := smoke_volume_material(noise) if smoke_volume else sprite_material(false, 2, ORDER_SMOKE)
	for sp in [column.far, column.near]:
		sp.node.material_override = mat
	# The volume's light; the sprites carry theirs baked into the texture.
	if smoke_volume:
		# A puff is drawn a fifth larger than the sphere it marches.
		for sp in [column.far, column.near]: sp.node.extra_cull_margin = 2.0

# A smoke puff: value-noise alpha (sin·cos is separable and cross-hatches) and a
# baked light-side gradient.
static var _smoke_tex: ImageTexture = null
static func smoke_texture() -> ImageTexture:
	if _smoke_tex != null: return _smoke_tex
	var s := 128
	var seed := PackedFloat32Array()
	seed.resize(64 * 64)
	for i in seed.size(): seed[i] = randf()
	var at := func(a: int, b: int) -> float:
		return seed[posmod(b, 64) * 64 + posmod(a, 64)]
	var vnoise := func(x: float, y: float) -> float:
		var xi := int(floor(x)); var yi := int(floor(y))
		var fx := x - xi; var fy := y - yi
		fx = fx * fx * (3.0 - 2.0 * fx); fy = fy * fy * (3.0 - 2.0 * fy)
		return lerpf(lerpf(at.call(xi, yi), at.call(xi + 1, yi), fx),
			lerpf(at.call(xi, yi + 1), at.call(xi + 1, yi + 1), fx), fy)
	var data := PackedByteArray()
	data.resize(s * s * 4)
	for y in s:
		for x in s:
			var dx := (x - s / 2.0) / (s / 2.0); var dy := (y - s / 2.0) / (s / 2.0)
			var d := sqrt(dx * dx + dy * dy)
			var n := 0.0; var amp := 0.5; var f := 3.5
			for o in 5:
				n += amp * vnoise.call(float(x) / s * f, float(y) / s * f)
				amp *= 0.5; f *= 2.13
			# The noise scales the radius rather than the alpha, then a power: mostly holes and
			# tendrils.
			var bite := pow(maxf(0.0, 1.0 - d * (0.58 + 0.95 * n)), 1.35)
			var a := bite * (0.18 + 1.15 * n * n)
			# Self-shading, as if lit from the upper left. Ambient occlusion in
			# the middle of the puff, highlight on the shoulder.
			var lit := 0.55 + 0.45 * maxf(0.0, -dx * 0.7 - dy * 0.7) + 0.25 * n
			var v := mini(255, int(U.jround(235.0 * minf(lit, 1.25))))
			var i := (y * s + x) * 4
			data[i] = v; data[i + 1] = v; data[i + 2] = mini(255, v + 4)
			data[i + 3] = mini(255, int(a * 255.0))
	var img := Image.create_from_data(s, s, false, Image.FORMAT_RGBA8, data)
	img.generate_mipmaps()
	_smoke_tex = ImageTexture.create_from_image(img)
	return _smoke_tex

# THE GROUND FLAME: the jet turned 90° by the deflector into a horizontal sheet.
# It exists while the jet still reaches the deck (height < reach) and spreads as the
# vehicle climbs. A flattened dome, brightest at the rim where the path is longest.
class GroundFlame extends RefCounted:
	var mesh: MeshInstance3D
	var material: ShaderMaterial
	var scale: float
	## Fan plan shape (x, z): a trench throws it along the trench axis; an open
	## deflector (Starship) in every direction.
	var aspect := Vector2.ONE

	##   throttle  0..1
	##   height    vehicle height above the deck, m
	##   reach     the plume's length, m
	func update(throttle: float, height: float, reach: float, time: float) -> void:
		# It is on while the jet still lands on the deck, and it dies as the
		# vehicle climbs out of its own exhaust. Nothing here is a timer.
		var hit := clampf(1.0 - height / maxf(reach, 1.0), 0.0, 1.0)
		var power := throttle * hit * hit
		mesh.visible = power > 0.004
		if not mesh.visible: return
		material.set_shader_parameter("uPower", power)
		material.set_shader_parameter("uTime", time)
		# The fan opens out as the vehicle rises: the jet arrives wider, and
		# more of it is turned before it gets there.
		var rad := scale * (1.0 + 1.8 * (1.0 - hit))
		# Flat. The fan is a sheet running along the ground, not a fireball —
		# it is the vertical momentum that has been taken OUT of the jet.
		mesh.scale = Vector3(rad * aspect.x, rad * 0.22, rad * aspect.y)

static func create_ground_flame(propellant, scale: float) -> GroundFlame:
	var P := _prop(propellant)
	var o := GroundFlame.new()
	o.scale = scale
	var m := ShaderMaterial.new()
	m.shader = shader("ground_flame")
	m.set_shader_parameter("uCore", _v3(P.core))
	m.set_shader_parameter("uEdge", _v3(P.edge))
	m.set_shader_parameter("uSoot", float(P.soot))
	m.set_shader_parameter("uTemp", float(P.T) * 0.82)   # it has already done work turning the corner
	m.render_priority = ORDER_FLAME
	o.material = m
	var mi := MeshInstance3D.new()
	mi.mesh = CraftModel._to_mesh(CraftModel._sphere(1.0, 40, 14, 0.0, TAU, 0.0, PI * 0.5), m)
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.visible = false
	o.mesh = mi
	return o
