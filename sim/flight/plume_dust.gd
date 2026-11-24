class_name PlumeDust
extends RefCounted

# The dust a landing plume raises, drawn only: where the jet meets the ground its pressure, the thrust over the
# disc it has spread to (wide in vacuum, confined in air), lifts the loose soil once it passes ONSET_PA, and the
# grains leave radially along the ground. In vacuum they fly flat and fast on ballistic paths, as the sheet
# under Apollo's LM did (1–3° up, Lane & Metzger 2012; 300–2000 m/s from Apollo-era pitting, fine dust faster
# still; drawn at the larger grains' 300–900); in air they
# slow in a few seconds, rise in the jet's turbulence and spread into a cloud, as the descent stage's camera saw
# under Perseverance (PIA24428). The onset and the spreads are estimates, set so that Apollo's LM (about 24 kN in
# its hover) starts to raise dust near 30 m, where Apollo 11's crew first called it, and the descent stage does
# at the 20 m of PIA24428. Site frame (x west, y up, z north), m and s. docs/physics/surface.md#a-landings-dust.

## Grains are lifted from this ground pressure, Pa, at full rate from FULL_PA.
const ONSET_PA := 5.0
const FULL_PA := 100.0
## The jet's half-angle by the time it meets the ground, rad: it expands freely in vacuum.
const SPREAD_VACUUM := 0.9
const SPREAD_AIR := 0.35
## Puffs a second at full rate, and at most this many alive.
const RATE := 160.0
const MAX := 900

var g := 1.62
var air := false
var pos := PackedVector3Array()
var vel := PackedVector3Array()
var age := PackedFloat32Array()
var life := PackedFloat32Array()
var size := PackedFloat32Array()
var count := 0
## The flight's clock at the last step, s.
var met := 0.0
var _owed := 0.0
var _rng := RandomNumberGenerator.new()
var view: MultiMeshInstance3D = null

func _init(gravity: float, has_air: bool, seed_ := 1) -> void:
	g = gravity
	air = has_air
	_rng.seed = seed_
	for a in [pos, vel]: a.resize(MAX)
	for a in [age, life, size]: a.resize(MAX)

## The jet's pressure on the ground `h` m under the nozzle, Pa.
static func ground_pressure(thrust: float, h: float, in_air: bool) -> float:
	var r := maxf(h, 0.3) * tan(SPREAD_AIR if in_air else SPREAD_VACUUM)
	return thrust / (PI * r * r)

## Lift and fly this step's dust. `hit`: where the jet meets the ground; `h`: the nozzle's height over it;
## `thrust`, N; `wind`, m/s in the site frame.
func step(dt: float, hit: Vector3, h: float, thrust: float, wind := Vector3.ZERO) -> void:
	var p := ground_pressure(thrust, h, air) if thrust > 0.0 else 0.0
	var k := clampf((p - ONSET_PA) / (FULL_PA - ONSET_PA), 0.0, 1.0)
	_owed += RATE * k * dt
	while _owed >= 1.0 and count < MAX:
		_owed -= 1.0
		var az := _rng.randf() * TAU
		var dir := Vector3(cos(az), 0.0, sin(az))
		var at := hit + dir * _rng.randf_range(0.2, 1.0) * maxf(h, 1.0) * tan(SPREAD_AIR if air else SPREAD_VACUUM) + Vector3.UP * 0.1
		var v: Vector3
		if air:
			v = dir * _rng.randf_range(5.0, 18.0) * (0.5 + 0.5 * k) + Vector3.UP * _rng.randf_range(1.0, 4.0)
		else:
			var u := _rng.randf_range(300.0, 900.0)
			var el := deg_to_rad(_rng.randf_range(1.0, 3.0))
			v = dir * u * cos(el) + Vector3.UP * u * sin(el)
		pos[count] = at
		vel[count] = v
		age[count] = 0.0
		life[count] = _rng.randf_range(3.0, 7.0) if air else _rng.randf_range(0.6, 1.2)
		size[count] = _rng.randf_range(0.6, 1.4) * (1.0 if air else 0.5)
		count += 1
	if _owed >= 1.0: _owed = 0.0
	var i := 0
	while i < count:
		var v := vel[i]
		if air:
			# Drag to the wind on a half-second time scale, fine grains in a thin wall jet; the cloud drifts up in
			# the jet's turbulence and settles.
			v = wind + (v - wind) * exp(-2.0 * dt)
			v.y += (0.4 - 0.05 * g * age[i]) * dt
		else:
			v.y -= g * dt
		pos[i] += v * dt
		vel[i] = v
		age[i] += dt
		if age[i] > life[i]:
			count -= 1
			pos[i] = pos[count]; vel[i] = vel[count]; age[i] = age[count]; life[i] = life[count]; size[i] = size[count]
			continue
		i += 1

## The puffs under `parent` (the site's group), in `tint` (sRGB).
func draw(parent: Node3D, tint: Color) -> void:
	if view == null:
		view = MultiMeshInstance3D.new()
		view.name = "plume_dust"
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.instance_count = MAX
		var quad := QuadMesh.new()
		var m := StandardMaterial3D.new()
		m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		m.billboard_keep_scale = true
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.vertex_color_use_as_albedo = true
		m.albedo_texture = _puff()
		m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
		quad.material = m
		mm.mesh = quad
		view.multimesh = mm
		view.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		view.custom_aabb = AABB(Vector3(-1e4, -1e3, -1e4), Vector3(2e4, 2e3, 2e4))
		parent.add_child(view)
	var mm2 := view.multimesh
	mm2.visible_instance_count = count
	for k in count:
		var t := age[k] / life[k]
		var s := size[k] * (1.0 + (4.0 if air else 2.0) * sqrt(t))
		mm2.set_instance_transform(k, Transform3D(Basis.from_scale(Vector3.ONE * s), pos[k]))
		var a := (0.24 if air else 0.18) * smoothstep(0.0, 0.08, t) * (1.0 - t)
		mm2.set_instance_color(k, Color(tint.r, tint.g, tint.b, a))

static var _tex: ImageTexture = null
static func _puff() -> ImageTexture:
	if _tex != null: return _tex
	var img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	for y in 64:
		for x in 64:
			var d := Vector2(x - 31.5, y - 31.5).length() / 32.0
			img.set_pixel(x, y, Color(1, 1, 1, clampf(1.0 - d, 0.0, 1.0) ** 1.6))
	_tex = ImageTexture.create_from_image(img)
	return _tex

func dispose() -> void:
	if view != null and is_instance_valid(view): view.queue_free()
	view = null
	count = 0
