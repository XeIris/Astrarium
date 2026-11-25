class_name SkyCraneRig
extends RefCounted

# What the Sky Crane does with its pieces that the stack does not, drawn on the CraftModel's stages from the
# vessel's state: the parachute over the backshell; the heat shield falling away ahead of it; the backshell left
# hanging on the parachute as the descent stage drops out below (Separation, with the shell's own drag); the rover
# going down the bridles by what the vessel has paid out; and, after touchdown, the cut, and the stage's climb,
# pitch-over and crash some 650 m off, its smoke rising where it hits (PIA24425). The flyaway is drawn, not flown.
# Craft frame, y up, m. docs/physics/sky-crane.md.

## The flyaway's timeline, s after touchdown: the cut, the climb, the pitch-over, gone from view.
const CUT_S := 1.0
const CLIMB_S := 2.0
const GONE_S := 16.0
## The crash: how far off, m, and how long its smoke rises and drifts, s.
const CRASH_M := 650.0
const SMOKE_S := 90.0

var craft: CraftModel.Craft
var shell: CraftModel.CraftStage
var desc: CraftModel.CraftStage
var rover: CraftModel.CraftStage
var shield: Array = []
var bridles: Array[MeshInstance3D] = []
var umbilical: MeshInstance3D
var canopy: Node3D = null
var _shield_sep = null
var _cable := 7.5
var _wheels := 0.0
var smoke: GPUParticles3D = null
## The rover has driven off on her own model: hers is no longer drawn here.
var deployed := false
var _flyaway_dir := Vector3(1.0, 0.0, 0.3).normalized()

## The rig for a craft with a descent stage over a datum rover, or null.
static func attach(c: CraftModel.Craft) -> SkyCraneRig:
	if c == null: return null
	var r := SkyCraneRig.new()
	r.craft = c
	for st: CraftModel.CraftStage in c.stages:
		var look: Dictionary = st.spec.get("look", {})
		if look.get("skycrane", false): r.desc = st
		elif look.get("datum", false): r.rover = st
		elif look.get("aeroshell", false): r.shell = st
	if r.desc == null or r.rover == null: return null
	if r.shell != null:
		for n in r.shell.group.find_children("*", "Node3D", true, false):
			if n.name.begins_with("heatshield") or n.name.begins_with("gore"): r.shield.append(n)
	if r.shell != null:
		var ch: Dictionary = r.shell.spec.get("chute", {})
		r.canopy = CraftModel.disk_gap_band(float(ch.get("D0", 21.5)))
		r.canopy.position.y = float(r.shell.spec.D)
		r.canopy.visible = false
		r.shell.group.add_child(r.canopy)
	r._wheels = r.rover.base_y
	var cable := StandardMaterial3D.new()
	cable.albedo_color = Color(0.85, 0.83, 0.78)
	cable.roughness = 0.8
	var umb := StandardMaterial3D.new()
	umb.albedo_color = Color(0.9, 0.88, 0.84)
	umb.roughness = 0.9
	for i in 3:
		var m := MeshInstance3D.new()
		m.mesh = _unit_cyl(0.008)
		m.material_override = cable
		m.visible = false
		c.group.add_child(m)
		r.bridles.append(m)
	r.umbilical = MeshInstance3D.new()
	r.umbilical.mesh = _unit_cyl(0.03)
	r.umbilical.material_override = umb
	r.umbilical.visible = false
	c.group.add_child(r.umbilical)
	return r

static func _unit_cyl(radius: float) -> CylinderMesh:
	var m := CylinderMesh.new()
	m.top_radius = radius
	m.bottom_radius = radius
	m.height = 1.0
	m.radial_segments = 6
	m.rings = 1
	return m

## The heat shield's own drag area as it falls blunt end first: a 70° sphere-cone's subsonic Cd is about 1 over
## its 15.9 m² (an estimate).
const SHIELD_CDA := 15.9

## Draw the moment. `s`: {shell, shield (attached), dt (simulated s), accel (the stack's non-gravitational
## acceleration, craft frame), air (Separation.step's), canopy (0..1 inflation, or < 0 with none out), bridle (m
## paid out), flyaway (s since touchdown, or < 0)}.
func update(s: Dictionary) -> void:
	var bridle := float(s.get("bridle", 0.0))
	rover.group.position.y = rover.base_y - bridle
	if deployed: rover.group.visible = false
	# Her wheels come down into place as the cables unreel.
	var rm: RoverModel = rover.group.get_meta("rover_model") if rover.group.has_meta("rover_model") else null
	if rm != null: rm.stow(1.0 - smoothstep(0.5, 4.0, bridle))
	if canopy != null:
		var open := float(s.get("canopy", -1.0))
		if open >= 0.0:
			canopy.visible = true
			# Out to its length first, then wide as the root of the drag area it gives.
			var w := maxf(sqrt(clampf(open, 0.0, 1.0)), 0.06)
			canopy.scale = Vector3(w, 1.0, w)
	var fly := float(s.get("flyaway", -1.0))
	# Landed on the cable, the vessel's reference comes down to her once it is cut; the stage does not.
	var up0 := _cable - bridle if fly >= CUT_S else 0.0
	var d_pos := Vector3(0.0, desc.base_y + up0, 0.0)
	var d_basis := Basis()
	if fly > CUT_S:
		var tau := fly - CUT_S
		var up := 1.5 * minf(tau, CLIMB_S) * minf(tau, CLIMB_S)
		var across := 0.0
		if tau > CLIMB_S:
			var t2 := tau - CLIMB_S
			up += 6.0 * t2 - 0.25 * t2 * t2
			across = 3.0 * t2 * t2
		d_pos += Vector3(0.0, up, 0.0) + _flyaway_dir * across
		d_basis = Basis(_flyaway_dir.cross(Vector3.UP).normalized(), -minf(maxf(tau - CLIMB_S, 0.0) * 0.4, PI * 0.25))
	desc.group.position = d_pos
	desc.group.basis = d_basis
	if fly > GONE_S:
		desc.group.visible = false
		# Nothing of the craft is left to draw once she has driven off.
		if deployed: craft.group.visible = false
	_fly_shield(s)
	# Bridles: from the descent stage's spool to her deck, three and the umbilical.
	var hang := bridle > 0.05 and fly < CUT_S
	if hang: _cable = maxf(bridle, 0.0)
	var deck_y := rover.group.position.y + 1.12
	var spool := desc.group.transform * Vector3(0.0, 0.0, 0.0)
	for i in 3:
		var a := TAU * i / 3.0 + 0.4
		var top := desc.group.transform * Vector3(cos(a) * 0.12, -0.02, sin(a) * 0.12)
		var bottom := Vector3(cos(a) * 0.55, deck_y, sin(a) * 0.45)
		_span(bridles[i], top, bottom, hang)
	_span(umbilical, spool, Vector3(0.3, deck_y, -0.35), hang)
	if fly > CUT_S + CLIMB_S + sqrt(CRASH_M / 3.0) and smoke == null: _crash()

# The heat shield once it is let go: Separation, with its own drag against the stack's on the parachute.
func _fly_shield(s: Dictionary) -> void:
	if shield.is_empty(): return
	var n: Node3D = shield[0]
	if not n.has_meta("rest"): n.set_meta("rest", n.transform)
	if bool(s.get("shield", true)):
		_shield_sep = null
		n.transform = n.get_meta("rest")
		n.visible = true
		return
	if _shield_sep == null:
		n.transform = n.get_meta("rest")
		var hs: Dictionary = shell.spec.get("heatShield", {})
		_shield_sep = Separation.start({"dry": float(hs.get("mass", 385.0)), "look": {"sep": {"canopy": {"CdA": SHIELD_CDA}}}},
			shell.group, [n], craft.group.basis)
	var left := float(s.get("dt", 0.0))
	var go := true
	while left > 0.0 and go:
		var h := minf(left, Separation.STEP)
		go = Separation.step(_shield_sep, h, craft.group.basis, s.get("accel", Vector3.ZERO), s.get("air", {}))
		left -= h
	n.visible = go and bool(s.get("shell", true))

func _span(m: MeshInstance3D, a: Vector3, b: Vector3, on: bool) -> void:
	m.visible = on
	if not on: return
	var d := b - a
	var y := d.normalized()
	var x := y.cross(Vector3.FORWARD if absf(y.z) < 0.9 else Vector3.RIGHT).normalized()
	m.transform = Transform3D(Basis(x, y * d.length(), x.cross(y)), (a + b) * 0.5)

# Smoke where it hit: a dark column that rises, spreads and thins, beside the craft (which a deployed rover
# hides) on its parent, in the craft's frame.
func _crash() -> void:
	var holder := craft.group.get_parent()
	if holder == null: return
	smoke = GPUParticles3D.new()
	smoke.name = "descent_stage_smoke"
	smoke.amount = 160
	smoke.lifetime = 30.0
	smoke.preprocess = 2.0
	smoke.one_shot = false
	smoke.visibility_aabb = AABB(Vector3(-200, -20, -200), Vector3(400, 500, 400))
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 6.0
	pm.direction = Vector3.UP
	pm.spread = 15.0
	pm.initial_velocity_min = 3.0
	pm.initial_velocity_max = 6.0
	pm.gravity = Vector3(1.0, 0.2, 0.0)
	pm.damping_min = 0.05
	pm.damping_max = 0.1
	var curve := CurveTexture.new()
	var cv := Curve.new()
	cv.add_point(Vector2(0.0, 0.3)); cv.add_point(Vector2(1.0, 1.0))
	curve.curve = cv
	pm.scale_curve = curve
	pm.scale_min = 10.0
	pm.scale_max = 16.0
	var fade := GradientTexture1D.new()
	var gr := Gradient.new()
	gr.set_color(0, Color(0.22, 0.19, 0.16, 0.55))
	gr.set_color(1, Color(0.35, 0.3, 0.26, 0.0))
	fade.gradient = gr
	pm.color_ramp = fade
	smoke.process_material = pm
	var quad := QuadMesh.new()
	quad.size = Vector2(1.0, 1.0)
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.vertex_color_use_as_albedo = true
	mat.albedo_texture = _puff()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	quad.material = mat
	smoke.draw_pass_1 = quad
	holder.add_child(smoke)
	smoke.transform = craft.group.transform * Transform3D(Basis(), _flyaway_dir * CRASH_M)
	smoke.emitting = true
	var stop := holder.get_tree().create_timer(SMOKE_S) if holder.is_inside_tree() else null
	if stop != null: stop.timeout.connect(func() -> void: if is_instance_valid(smoke): smoke.emitting = false)

static var _puff_tex: ImageTexture = null
static func _puff() -> ImageTexture:
	if _puff_tex != null: return _puff_tex
	var img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	for y in 64:
		for x in 64:
			var d := Vector2(x - 31.5, y - 31.5).length() / 32.0
			img.set_pixel(x, y, Color(1, 1, 1, clampf(1.0 - d, 0.0, 1.0) ** 2))
	_puff_tex = ImageTexture.create_from_image(img)
	return _puff_tex

## Let go of what it added outside the craft.
func dispose() -> void:
	if smoke != null and is_instance_valid(smoke): smoke.queue_free()
	smoke = null
