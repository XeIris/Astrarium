class_name SkyCraneRig
extends RefCounted

# What the Sky Crane does with its pieces that the stack does not, drawn on the CraftModel's stages from the
# vessel's state: the parachute over the backshell; the heat shield falling away ahead of it; the backshell left
# hanging on the parachute as the descent stage drops out below (Separation, with the shell's own drag); the rover
# going down the bridles by what the vessel has paid out; and, after touchdown, the cut, the stage on its flyaway
# (CraneFlyaway) and the smoke where it hits (PIA24425).
# Craft frame, y up, m. docs/physics/sky-crane.md.

## The bridles are cut this long after touchdown, s, and the crash's smoke rises and drifts for SMOKE_S.
const CUT_S := 1.0
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
var _wheels := 0.0
var smoke: MultiMeshInstance3D = null
## The rover has driven off on her own model: hers is no longer drawn here.
var deployed := false

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
## paid out), down (s since touchdown, or < 0), away ({at, basis, hit, up, wind, age, day} of the descent stage on its flyaway, craft
## frame, `hit` true once it has crashed there, `age` s ago, in this wind and daylight; empty before the cut)}.
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
	var since := float(s.get("down", -1.0))
	var away: Dictionary = s.get("away", {})
	desc.group.position = Vector3(0.0, desc.base_y, 0.0)
	desc.group.basis = Basis()
	if not away.is_empty():
		desc.group.position = away.at
		desc.group.basis = away.basis
		if bool(away.hit):
			desc.group.visible = false
			# Nothing of the craft is left to draw once she has driven off.
			if deployed: craft.group.visible = false
			_burn_smoke(away.at, away.up, away.wind, float(away.age), float(away.day))
	_fly_shield(s)
	# Bridles: from the descent stage's spool to her deck, three and the umbilical.
	var hang := bridle > 0.05 and since < CUT_S
	var deck_y := rover.group.position.y + 1.12
	var spool := desc.group.transform * Vector3(0.0, 0.0, 0.0)
	for i in 3:
		var a := TAU * i / 3.0 + 0.4
		var top := desc.group.transform * Vector3(cos(a) * 0.12, -0.02, sin(a) * 0.12)
		var bottom := Vector3(cos(a) * 0.55, deck_y, sin(a) * 0.45)
		_span(bridles[i], top, bottom, hang)
	_span(umbilical, spool, Vector3(0.3, deck_y, -0.35), hang)

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

# Smoke where it hit, `age` s on: PUFFS of it let go over SMOKE_S, each rising, spreading and thinning, drifting with
# the wind, all from the age alone. Beside the craft (which a deployed rover hides), on its parent.
const PUFFS := 220
const PUFF_LIFE := 70.0
func _burn_smoke(at: Vector3, up: Vector3, wind: Vector3, age: float, day: float) -> void:
	var holder := craft.group.get_parent()
	if holder == null: return
	if smoke == null:
		smoke = MultiMeshInstance3D.new()
		smoke.name = "descent_stage_smoke"
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.instance_count = PUFFS
		var quad := QuadMesh.new()
		var mat := StandardMaterial3D.new()
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		mat.billboard_keep_scale = true
		mat.vertex_color_use_as_albedo = true
		mat.albedo_texture = PlumeDust._puff()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
		quad.material = mat
		mm.mesh = quad
		smoke.multimesh = mm
		smoke.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		smoke.custom_aabb = AABB(Vector3(-2e3, -2e3, -2e3), Vector3(4e3, 4e3, 4e3))
		holder.add_child(smoke)
	smoke.transform = craft.group.transform * Transform3D(Basis(), at)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var n := 0
	for k in PUFFS:
		var jx := rng.randf_range(-1.0, 1.0); var jz := rng.randf_range(-1.0, 1.0); var ju := rng.randf_range(0.75, 1.25)
		# Most of it at once, from the impact, then what the propellant left feeds.
		var t := age - SMOKE_S * pow(float(k) / PUFFS, 1.8)
		if t < 0.0 or t > PUFF_LIFE: continue
		var f := t / PUFF_LIFE
		var size := 8.0 + 1.1 * t * ju
		var rise := 3.2 * ju * t * (1.0 - 0.35 * f)
		var pos := up * (rise + size * 0.25) + wind * (0.25 * t) + Vector3(jx, 0.0, jz) * (3.0 + 0.25 * t)
		smoke.multimesh.set_instance_transform(n, Transform3D(Basis.from_scale(Vector3.ONE * size), pos))
		var c := Color(lerpf(0.16, 0.42, f), lerpf(0.13, 0.32, f), lerpf(0.1, 0.23, f)) * day
		c.a = 0.34 * smoothstep(0.0, 0.03, f) * pow(1.0 - f, 1.4)
		smoke.multimesh.set_instance_color(n, c)
		n += 1
	smoke.multimesh.visible_instance_count = n
	smoke.visible = n > 0

## Let go of what it added outside the craft.
func dispose() -> void:
	if smoke != null and is_instance_valid(smoke): smoke.queue_free()
	smoke = null
