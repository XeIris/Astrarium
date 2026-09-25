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

static var _sh := {}
static func shader(name: String) -> Shader:
	if not _sh.has(name):
		_sh[name] = load("res://shaders/flight/%s.gdshader" % name)
	return _sh[name]

static func _v3(a: Array) -> Vector3:
	return Vector3(a[0], a[1], a[2])

static func _prop(name) -> Dictionary:
	return PROPELLANT.get(name, PROPELLANT.kerolox) if name != null else PROPELLANT.kerolox

## A THREE.CylinderGeometry WITH its uv attribute (craftmodel's Geo carries
## none, and the plume's azimuth IS uv.x): open-ended, translated so the top
## sits at y = 0 and the tube runs down −Y. Index winding is swapped once for
## Godot, as craftmodel's _to_mesh does.
static func _tube_mesh(r: float, L: float, radial: int, hseg: int) -> ArrayMesh:
	var pos := PackedVector3Array()
	var nrm := PackedVector3Array()
	var uv := PackedVector2Array()
	var idx := PackedInt32Array()
	for y in hseg + 1:
		var v := float(y) / hseg
		for x in radial + 1:
			var u := float(x) / radial
			var th := u * TAU
			# three: y = −v·L + L/2, then geo.translate(0, −L/2, 0)
			pos.append(Vector3(r * sin(th), -v * L, r * cos(th)))
			nrm.append(Vector3(sin(th), 0.0, cos(th)))
			uv.append(Vector2(u, 1.0 - v))
	for x in radial:
		for y in hseg:
			var a := y * (radial + 1) + x
			var b := (y + 1) * (radial + 1) + x
			var c := (y + 1) * (radial + 1) + x + 1
			var d := y * (radial + 1) + x + 1
			# three: (a, b, d), (b, c, d) — reversed for Godot's clockwise fronts
			idx.append_array([a, d, b, b, d, c])
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = pos
	arr[Mesh.ARRAY_NORMAL] = nrm
	arr[Mesh.ARRAY_TEX_UV] = uv
	arr[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return m

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
	## The length the jet is BUILT at, reported rather than left to be
	## reconstructed by anything downstream: the beam multiplier is not
	## guessable from exit_d, and the pad flame goes out on this number.
	var reach: float
	var exit_d: float
	var stage_key := ""
	var engine = null

	## @param throttle 0..1 @param pa ambient pressure, Pa @param p0 reference (sea level)
	func update(throttle: float, pa: float, time: float, p0: float = 101325.0) -> void:
		var on := throttle > 0.001
		mesh.visible = on
		if not on: return
		var P := propellant
		material.set_shader_parameter("uThrottle", 0.35 + 0.65 * throttle)
		# Expansion state: 0 in a sea-level atmosphere, 1 in vacuum. The plume's
		# whole shape follows this one number.
		var ex := clampf(1.0 - pa / p0, 0.0, 1.0)
		material.set_shader_parameter("uExpand", ex)
		material.set_shader_parameter("uTime", time)
		# The glow sits a little inside the exit plane — the flash comes from the
		# gas in the bell, not from a disc hanging in front of it — and grows
		# with the plume, because in vacuum there is far more radiating gas.
		var beam: bool = P.get("beam", false)
		glow.position.y = -exit_d * 0.35
		var s := exit_d * (2.2 + 3.4 * ex) * (0.6 + 0.4 * throttle) * (0.35 if beam else 1.0)
		glow.scale = Vector3(s, s, s)
		glow.set_instance_shader_parameter("opacity", (0.18 if beam else 0.85) * float(P.glow) * (0.45 + 0.55 * throttle))

## One engine's plume. `exit_d` sets the scale; everything else is driven per
## frame from the flight state.
static func create_plume(propellant, exit_d: float, length_scale: float = 18.0) -> PlumeFx:
	var P := _prop(propellant)
	var beam: bool = P.get("beam", false)
	var L := exit_d * length_scale * (2.4 if beam else 1.0)
	var fx := PlumeFx.new()
	fx.propellant = P
	fx.reach = L
	fx.exit_d = exit_d
	var m := ShaderMaterial.new()
	m.shader = shader("plume")
	m.set_shader_parameter("uCore", _v3(P.core))
	m.set_shader_parameter("uEdge", _v3(P.edge))
	m.set_shader_parameter("uSoot", float(P.soot))
	m.set_shader_parameter("uGlow", float(P.glow))
	m.set_shader_parameter("uTemp", float(P.T))
	m.set_shader_parameter("uBeam", 1.0 if beam else 0.0)
	m.set_shader_parameter("uDiamonds", 0.0 if beam else 1.0)
	m.set_shader_parameter("uLen", L)
	m.render_priority = ORDER_FLAME
	fx.material = m
	# A straight tube at the NOZZLE'S OWN EXIT RADIUS. All the shaping is in the
	# vertex shader, where it is a function of the pressure ratio, so the
	# geometry must not pre-empt any of it — a tapered tube would multiply a
	# taper by a taper and the sea-level jet came out a third the width.
	var jet := MeshInstance3D.new()
	jet.mesh = _tube_mesh(exit_d * 0.5, L, 28, 30)
	jet.material_override = m
	jet.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# frustumCulled = false: the vertex shader blooms it up to 5.3× wide and
	# 2.3× long, far outside the tube's own box.
	jet.custom_aabb = AABB(Vector3(-L * 3.0, -L * 2.5, -L * 3.0), Vector3(L * 6.0, L * 2.6, L * 6.0))
	fx.jet = jet

	# THE NOZZLE IS A LIGHT SOURCE, and a jet drawn as a tube is not one. The
	# exit plane is the hottest thing on the vehicle and it is looked at down
	# its own axis half the time, where a tube presents almost no area. A
	# camera-facing glow at the exit is the part of an engine you actually see
	# first: it is why a rocket at twenty kilometres is a star, not a shape.
	var glow := make_sprite(sprite_material(true, 0, ORDER_FLAME))
	# color.setRGB(...) — floats, so NOT colour-converted
	glow.set_instance_shader_parameter("tint", Vector3(
		minf(1.0, P.core[0] * 1.1 + 0.25), minf(1.0, P.core[1] * 1.1 + 0.2), minf(1.0, P.core[2] * 1.1 + 0.15)))
	fx.glow = glow

	var g := Node3D.new()
	g.name = "plume"
	g.add_child(jet)
	g.add_child(glow)
	g.visible = false
	fx.mesh = g
	return fx

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
		mesh.scale = Vector3(rad, rad * 0.22, rad)

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
