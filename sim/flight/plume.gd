class_name Plume
extends RefCounted

# ============================================================================
# EXHAUST, PLASMA AND SMOKE — port of sim/flight/plume.js.
# ----------------------------------------------------------------------------
# The plume's SHAPE is a function of ambient pressure and nothing else, so one
# shader covers sea level, vacuum and everything in between — which is the
# effect worth having, because you watch it happen during the climb.
#
#   OVER-EXPANDED (low altitude, p_e < p_a): the outside air squeezes the jet
#   into a narrow column, and it recompresses to ambient through a train of
#   oblique shocks — the SHOCK DIAMONDS. Bright where the gas is compressed and
#   heated, dark where it expands again. Three to five are visible on a Falcon 9
#   at liftoff, and their spacing grows as the air thins.
#
#   UNDER-EXPANDED (vacuum, p_e > p_a): nothing confines it, so it opens into a
#   huge translucent bell many times the nozzle diameter and the diamonds
#   disappear entirely. This is why an upper stage looks like it has an enormous
#   ghost of a flame and a first stage looks like a blowtorch.
#
# COLOUR IS THE PROPELLANT, not taste. RP-1/LOX is soot-luminous orange because
# it is burning carbon; LH2/LOX is nearly invisible pale violet because it is
# burning to water with almost no continuum emitter in it; methalox is blue with
# an orange core; a solid is a white-orange torch behind an enormous grey-white
# cloud of aluminium oxide. An ion engine is not a flame at all — it is a
# collimated beam of xenon ions recombining, so it is dim, narrow, does not
# flicker, and must not look powerful at 237 mN.
#
# ALPHA WAS THE TEMPERATURE CHANNEL in the web build. Every emitter published
# its true temperature into the HDR buffer's alpha (α = ln T / 25.33) with the
# RGB added at a source factor of that same α, and every sprite left the
# channel alone. The Godot local pass has no temperature channel at all — its
# alpha is COVERAGE, and render/compose.glsl reads local coverage as "no data"
# (PORT_GUIDE §6) — so here:
#   · emitters (jet, entry sheath, ground flame) form rgb × code in the shader
#     and blend ONE, ONE (blend_premul_alpha, ALPHA = 0): the same light, and
#     no coverage, so the orrery behind a plume shows through undimmed;
#   · the engine glow and the RCS puffs are additive sprites the same way;
#   · the smoke is blend_mix, which raises coverage — smoke is the one thing
#     here that genuinely hides what is behind it.
# What this loses is the plume's own temperature in the non-visible bands; the
# local pass images from colour there.
#
# PORT NOTES
#   · createPlume/createRCSPuffs/createEntryGlow/createSmokeColumn/
#     createGroundFlame become create_plume/create_rcs_puffs/create_entry_glow/
#     create_smoke_column/create_ground_flame, each returning an inner-class
#     object with the JS fields (mesh/group, uniforms → the ShaderMaterial,
#     reach, update(), emit(), clear()).
#   · THREE.Sprite becomes a camera-facing quad (shaders/flight/sprite*.gdshader)
#     with per-object INSTANCE uniforms for the colour, opacity and rotation the
#     web build kept on one SpriteMaterial per sprite.
#   · renderOrder becomes render_priority (LocalView.ORDER); Godot, like three,
#     sorts it only within the transparent list.
# ============================================================================

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
	# The spin drive radiates at 25.98 µm — deep infrared, and invisible. What is
	# drawn is the visible tail of a source that is overwhelmingly not visible,
	# which is why it is a faint red haze and not a torch.
	"spin":       { "T": 1500.0, "core": [1.00, 0.30, 0.18], "edge": [0.55, 0.06, 0.04], "soot": 0.0, "glow": 0.45, "beam": true },
}

# ---------------------------------------------------------------------------
# WHAT EACH PROPELLANT LOOKS LIKE, as emission per unit path in HDR — the
# volume in shaders/flight/plume.gdshader integrates these along the ray.
#
#   kerolox     soot-luminous: a yellow-white core, then an orange afterburning
#               mixing layer that is most of the light, cooling to deep red and
#               brown-black smoke
#   hydrolox    burns to water with almost no continuum emitter, so it is nearly
#               INVISIBLE in daylight — what shows are the shock cells, where
#               compression reheats the gas, and a faint violet-blue OH glow
#   methalox    blue from CH and C₂ band emission in the core; little soot, so a
#               pink-orange afterburning fringe rather than an orange torch
#   solid       aluminium burning to alumina droplets at ~3000 K: a white-yellow
#               torch you cannot look at, inside the enormous white cloud those
#               same droplets make as they cool
#   hypergolic  pale, translucent, peach — and in vacuum close to invisible
#   ion         a collimated xenon beam: dim, blue, perfectly steady
#   spin        the book's astrophage drive radiates at 25.98 µm, far in the
#               infrared; what is drawn is the faint visible tail of an almost
#               entirely invisible beam, a deep red haze on the axis
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# WHAT MAKES ONE ENGINE'S PLUME ITS OWN. Exit pressure p_e and exit Mach are
# published figures (or follow from the published expansion ratio and chamber
# pressure); against the ambient they give the pressure ratio the whole shape
# is built on. So a Merlin (p_e ≈ 0.6 atm) is gently over-expanded at the pad
# and shows a train of soft diamonds, and an RS-25 (p_e ≈ 0.16 atm, 69:1 on a
# 206-bar chamber) is violently over-expanded and hangs a white Mach disk under
# each bell — which is the Shuttle's liftoff picture, from the same one number.
# Vacuum engines exhaust at a few kPa, so they bloom the moment the air thins.
#
#   F-1   the gas-generator exhaust was dumped into the nozzle extension as a
#         film coolant: a dark, fuel-rich sleeve round the first diameters of
#         the jet that ignites raggedly further down — `film`
#   RSRM  alumina: the soot is WHITE (it scatters), see LOOK.solid
# ---------------------------------------------------------------------------
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

## How brightly the local scene is lit, relative to full sun at Earth: the
## smoke a plume scatters is only as bright as the light falling on it.
## spaceflight.gd sets it each frame.
static var daylight := 1.0

static var _sh := {}
static func shader(name: String) -> Shader:
	if not _sh.has(name):
		_sh[name] = load("res://shaders/flight/%s.gdshader" % name)
	return _sh[name]

static func _v3(a: Array) -> Vector3:
	return Vector3(a[0], a[1], a[2])

static func _prop(name) -> Dictionary:
	return PROPELLANT.get(name, PROPELLANT.kerolox) if name != null else PROPELLANT.kerolox

## A closed unit cylinder, y from −1 to 0 — the plume's bounding volume. The
## shader scales it by uBox and marches the field inside; only its back faces
## are drawn, so it covers every pixel the plume can reach from any viewpoint,
## including from inside it.
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
		# outward-facing (three's counter-clockwise, which _to_mesh turns
		# into Godot's clockwise): the shader culls FRONT faces, so what is
		# drawn is the far wall — or every wall, from inside
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
## colour, opacity and rotation as instance uniforms.
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

## A sprite: a quad MeshInstance3D whose instance uniforms are its SpriteMaterial.
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

# ============================================================================
# ONE ENGINE'S PLUME
# ============================================================================
class PlumeFx extends RefCounted:
	var mesh: Node3D               # the group hung on the gimbal pivot
	var jet: MeshInstance3D
	var glow: MeshInstance3D
	var material: ShaderMaterial   # the web build's `uniforms`
	var propellant: Dictionary
	var look: Dictionary
	## The length the jet is BUILT at, reported rather than left to be
	## reconstructed by anything downstream: the beam multiplier is not
	## guessable from exit_d, and the pad flame goes out on this number.
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

	## @param throttle 0..1 @param pa ambient pressure, Pa @param p0 reference (sea level)
	func update(throttle: float, pa: float, time: float, _p0: float = 101325.0) -> void:
		var on := throttle > 0.001
		mesh.visible = on
		if light != null: light.visible = on
		if not on: return
		var pr := pe / maxf(pa, 1e-3)
		material.set_shader_parameter("uThrottle", throttle)
		material.set_shader_parameter("uPR", pr)
		material.set_shader_parameter("uTime", time)
		var sm: Vector3 = Plume._v3(look.smoke) * Plume.daylight
		material.set_shader_parameter("uSmoke", sm)
		# The bounding cylinder follows the jet: a pencil at the pad, a bell
		# many diameters across in vacuum, and shorter when throttled back —
		# the afterburning mixing layer is most of the length, and a throttled
		# engine has less to burn.
		var under := clampf(log(maxf(pr, 1.0)) / log(300.0), 0.0, 1.0)
		var re := exit_d * 0.5
		var L := reach * (1.0 + 1.3 * under) * (0.55 + 0.45 * throttle)
		if beam: L = reach
		var lx := L / exit_d
		var rj := 1.0 + under * 2.6 * pow(lx, 0.62) + maxf(0.14 * (1.0 - under), 0.05) * lx
		if beam: rj = 1.0 + 0.03 * lx
		var R := re * rj * 1.9
		material.set_shader_parameter("uBox", Vector3(R, L, R))
		# The exit glow sits a little inside the exit plane — the flash comes
		# from the gas in the bell — and grows with the plume, because in vacuum
		# there is far more radiating gas.
		if glow != null:
			glow.position.y = -exit_d * 0.08
			var s := exit_d * (1.6 + 2.4 * under) * (0.6 + 0.4 * throttle) * (0.35 if beam else 1.0)
			glow.scale = Vector3(s, s, s)
			glow.set_instance_shader_parameter("opacity", (0.18 if beam else 0.75) * float(propellant.glow) * (0.45 + 0.55 * throttle))
		if light != null:
			light.light_energy = light_scale * throttle * (0.4 if beam else 1.0)

## One engine's plume. `exit_d` sets the scale; everything else is driven per
## frame from the flight state. `engine` is the vehicles.gd entry (for its own
## exit pressure and look); `role` is "single", "near" (one engine of a cluster
## whose far field is drawn merged) or "far" (that merged far field).
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
	m.set_shader_parameter("uTempCode", clampf(log(maxf(float(P.T), 2.0)) / 25.33, 0.006, 0.984))
	# a cluster's single engines only draw their first few diameters
	m.set_shader_parameter("uSteps", 14 if role == "near" else (22 if role == "far" else 26))
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
	# THE NOZZLE IS A LIGHT SOURCE: the exit plane is the hottest thing on the
	# vehicle and is looked at down its own axis half the time. A merged far
	# field has no nozzle of its own, so no glow.
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

## Give a plume the light its flame throws. Its colour is the mixing layer's
## (the part of the flame with the most area), its reach a few dozen exit
## diameters, and its energy what makes a pad at night orange rather than dark.
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

# ============================================================================
# RCS — short, cold, translucent puffs. They matter because they are the only
# visible sign that the vehicle is holding attitude.
# ============================================================================
class RCSPuffs extends RefCounted:
	var group: Node3D
	var puffs: Array = []          # [{sprite, life, dir, size}]
	var next := 0

	## Fire a puff at a local position, in a local direction.
	func fire(pos: Vector3, dir: Vector3, size: float = 1.0) -> void:
		next = (next + 1) % puffs.size()
		var p: Dictionary = puffs[next]
		var s: MeshInstance3D = p.sprite
		s.position = pos + dir * (size * 0.6)
		s.scale = Vector3(size, size, size)
		p.life = 1.0; s.visible = true; p.dir = dir; p.size = size

	func update(dt: float) -> void:
		for p in puffs:
			if p.life <= 0.0: continue
			p.life -= dt * 4.5
			var s: MeshInstance3D = p.sprite
			if p.life <= 0.0:
				s.visible = false
				continue
			s.set_instance_shader_parameter("opacity", p.life * 0.55)
			var k: float = p.size * (1.0 + (1.0 - p.life) * 2.2)
			s.scale = Vector3(k, k, k)
			s.position += p.dir * (dt * p.size * 4.0)

static func create_rcs_puffs(count: int = 12) -> RCSPuffs:
	var o := RCSPuffs.new()
	o.group = Node3D.new()
	o.group.name = "rcs"
	var mat := sprite_material(true, 1, ORDER_FLAME)
	for i in count:
		var s := make_sprite(mat)
		s.set_instance_shader_parameter("tint", _lin3(0xbfd8ff))
		s.visible = false
		o.group.add_child(s)
		o.puffs.append({"sprite": s, "life": 0.0, "dir": Vector3.ZERO, "size": 1.0})
	return o

static func _lin3(hex: int) -> Vector3:
	var c := U.lin(hex)
	return Vector3(c.r, c.g, c.b)

# ============================================================================
# RE-ENTRY PLASMA
# ----------------------------------------------------------------------------
# A bow-shock cap ahead of the vehicle whose brightness and colour follow the
# Sutton–Graves heat flux — the same number that is burning the shield down and
# that will destroy the vehicle if it gets too large. So nothing here is
# decorative: if you see a lot of it, you are in trouble, and the HUD agrees.
# ============================================================================
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

# ============================================================================
# LAUNCH SMOKE — the ground cloud, which only exists where there is an
# atmosphere AND a surface to bounce off. It is billboards rather than a
# volume, because that is what a few hundred of them can afford to be.
# ============================================================================
class SmokeColumn extends RefCounted:
	var group: Node3D
	var parts: Array = []     # [{s, life, rate, spin, rot, vel, color, dirty}]
	var next := 0
	# TWO CLOUDS, NOT ONE, and they are made of different substances.
	#
	#   STEAM is the deluge flashing off the deck — a million litres of water in
	#   forty seconds. It is brilliant white, it is most of the VOLUME, and it
	#   dies quickly because it condenses and rains back out.
	#
	#   SOOT is the exhaust: unburnt carbon out of a fuel-rich kerosene engine,
	#   or aluminium oxide out of a solid. It is dark, it is what the column is
	#   still made of a minute later, and it is the reason the base of a launch
	#   cloud is brown and the top is white.
	#
	# Drawing only the white half is what makes a rendered launch look like a
	# fog machine. The mix follows the propellant's own soot fraction, so a
	# hydrogen launch is genuinely almost clean and a solid is filthy.
	var STEAM := U.lin(0xe8eaec)
	var SOOT := U.lin(0x4a423a)

	## Emit at the pad. `power` is the thrust fraction; `spread` is in metres.
	func emit(origin: Vector3, power: float, spread: float, dt: float, soot: float = 0.7) -> void:
		var n := mini(9, int(ceil(power * 44.0 * dt)))
		for k in n:
			next = (next + 1) % parts.size()
			var p: Dictionary = parts[next]
			var s: MeshInstance3D = p.s
			var a := randf() * PI * 2.0
			var r := spread * (0.2 + randf() * 0.9)
			s.position = Vector3(origin.x + cos(a) * r, origin.y + randf() * spread * 0.2, origin.z + sin(a) * r)
			# The cloud rolls OUTWARD first and only then rises — the deflected
			# exhaust is going sideways at the speed of sound.
			p.vel = Vector3(cos(a) * spread * (0.7 + randf()), spread * 0.25 * randf(),
				sin(a) * spread * (0.7 + randf()))
			# Soot is thrown out with the exhaust and stays low and near the
			# middle; steam boils off the whole deck. So which one a puff is
			# depends on where it started — the dark core inside the white.
			var dirty := randf() < soot * (1.0 - 0.55 * (r / spread))
			var c: Color = SOOT if dirty else STEAM
			# No two puffs the same value, or several hundred of them read as
			# one flat sheet however well each is shaded.
			var k2 := 0.80 + randf() * 0.35
			p.color = Color(c.r * k2, c.g * k2, c.b * k2)
			s.set_instance_shader_parameter("tint", Vector3(p.color.r, p.color.g, p.color.b))
			p.dirty = dirty
			# Soot survives; steam condenses out. That difference in lifetime is
			# what leaves a dark column standing after the white has gone.
			p.rate = 0.10 if dirty else 0.30
			p.life = 1.0; s.visible = true
			var sc := spread * (0.6 + randf() * 0.8)
			s.scale = Vector3(sc, sc, sc)
			p.rot = randf() * 6.28
			s.set_instance_shader_parameter("rot", p.rot)
			# Rolling, because a puff that holds its orientation while it grows
			# reads as a decal rather than as a turbulent lump.
			p.spin = (randf() - 0.5) * 0.5

	func update(dt: float) -> void:
		for p in parts:
			if p.life <= 0.0: continue
			p.life -= dt * p.rate
			var s: MeshInstance3D = p.s
			if p.life <= 0.0:
				s.visible = false
				continue
			s.position += p.vel * dt
			p.vel *= 1.0 - dt * 0.7
			p.vel.y += dt * 2.4                       # buoyancy: it is hot
			s.scale *= 1.0 + dt * 0.55
			p.rot += p.spin * dt
			s.set_instance_shader_parameter("rot", p.rot)
			# Entrained air cools and dilutes it, so a puff pales as it ages —
			# the dark core is dark because it is YOUNG, not for ever.
			if p.dirty:
				p.color = p.color.lerp(STEAM, dt * 0.10)
				s.set_instance_shader_parameter("tint", Vector3(p.color.r, p.color.g, p.color.b))
			s.set_instance_shader_parameter("opacity", pow(p.life, 1.4) * (0.62 if p.dirty else 0.45))

	func clear() -> void:
		for p in parts:
			p.life = 0.0
			(p.s as MeshInstance3D).visible = false

static func create_smoke_column(count: int = 150) -> SmokeColumn:
	var o := SmokeColumn.new()
	o.group = Node3D.new()
	o.group.name = "smoke"
	var mat := sprite_material(false, 2, ORDER_SMOKE)
	for i in count:
		var s := make_sprite(mat)
		s.set_instance_shader_parameter("tint", _lin3(0xd8d8d4))
		s.visible = false
		o.group.add_child(s)
		o.parts.append({"s": s, "life": 0.0, "rate": 1.0, "spin": 0.0, "rot": 0.0, "vel": Vector3.ZERO,
			"color": Color(1, 1, 1), "dirty": false})
	return o

# A puff of smoke. The alpha is VALUE NOISE, not a product of a sine and a
# cosine — sin(x)·cos(y) is separable, which means its level sets are a grid,
# which means every sprite in the cloud carried the same diagonal lattice and
# a few hundred of them overlapping turned the whole launch cloud into visible
# cross-hatching. Real noise has no preferred direction, which is the entire
# property being asked for here.
#
# The shading is not flat either: a smoke puff is a lump of scattering medium
# lit from one side, so it is bright where it faces the light and dark in its
# own shadow. One texture with a baked gradient does more for a cloud than any
# number of extra sprites.
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
			# The noise EATS the disc — it scales the radius rather than
			# modulating the alpha on top of it — and then the alpha is taken to
			# a power, so the puff is mostly holes and tendrils.
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

# ============================================================================
# THE GROUND FLAME — what the exhaust does after it hits the deck.
# ----------------------------------------------------------------------------
# For the first two or three vehicle lengths of a launch the jet is not going
# anywhere: it hits the deflector and turns through ninety degrees, and what
# comes out is a horizontal sheet of burning gas thrown out along the trench
# faster than it went down. That fan is the largest, brightest thing in the
# frame at T+0, and it is the reason a pad at ignition looks nothing like a
# rocket with a flame under it.
#
# Two things drive it and both are physical:
#
#   IMPINGEMENT — it exists only while the jet still reaches the deck, i.e.
#   while the vehicle's height above the pad is less than the plume is long.
#   It does not fade out on a timer; it goes out because the rocket left.
#
#   SPREAD — the fan's radius grows as the vehicle climbs, because the jet
#   arrives at the deck wider and with more of its momentum already turned by
#   the air. So it opens out and thins at the same time, which is exactly what
#   the ring of fire under a Saturn V does in the first five seconds.
#
# Drawn as a flattened dome rather than a disc: the sheet has thickness, it is
# brightest where you look ALONG it — out at the rim, where the path through
# the burning gas is longest — and a flat disc has none of that.
# ============================================================================
class GroundFlame extends RefCounted:
	var mesh: MeshInstance3D
	var material: ShaderMaterial
	var scale: float
	## The fan's plan shape, (along x, along z). A flame TRENCH turns the jet
	## through ninety degrees and sends it out of both ends, so the fire runs
	## along the trench (site x) and is narrow across it; a mount with an open
	## deflector under it (Starship's) throws it out in every direction.
	var aspect := Vector2.ONE

	## @param throttle 0..1
	## @param height   the vehicle's height above the deck, m
	## @param reach    how far the jet carries — the plume's own length, m
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
