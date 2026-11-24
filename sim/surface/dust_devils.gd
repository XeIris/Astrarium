class_name DustDevils
extends RefCounted

# Dust devils about a site on a dry world with air, drawn only: convective vortices that form where the
# Sun heats the ground, so none at night and most from late morning to mid afternoon, and drift with the
# wind until they die. The rate is Jezero's: Newman et al. 2022 found about four vortices passing
# Perseverance a sol, over a quarter of them dusty; sizes and lives are estimates within what Mars rovers and
# orbiters have measured, and a stated `scale` multiplies the rate for a showcase. Site frame (x west, y up,
# z north), m and s. docs/physics/surface.md#dust-devils.

## Dusty devils born per km² per sol, and how far about the eye they are kept, m. One dusty encounter a sol over
## the ~0.09 km² a devil sweeps within 30 m of a point (1.5 km of drift) is about 11.
const RATE_KM2_SOL := 10.0
const FIELD_M := 2500.0
## A devil's life, s; its core diameter, m; its height, m (Mars: tens of metres across, hundreds up).
const LIFE := [120.0, 900.0]
const DIAMETER := [8.0, 60.0]
const HEIGHT := [150.0, 900.0]
## The swirl at the core's edge, m/s (MEDA's vortex encounters: up to about 20).
const SWIRL := 14.0
const PUFFS := 70
const MAX := 12

var devils: Array = []        # [{id, at: Vector2 (east, north), born, life, d, h, phase, wander}]
var scale := 1.0
var _rng := RandomNumberGenerator.new()
var _t := 0.0
var _owed := 0.0
var _next_id := 0
var view: MultiMeshInstance3D = null

func _init(seed_ := 1) -> void:
	_rng.seed = seed_

## How strongly the ground drives convection with the Sun `elev` rad up: none below 15°.
static func heating(elev: float) -> float:
	return clampf((sin(elev) - 0.26) / 0.74, 0.0, 1.0)

## Spawn, drift and retire. `wind`: m/s toward (east, north); `eye`: (east, north), m; `sol_s`: the world's
## solar day, s.
func step(dt: float, elev: float, wind: Vector2, eye: Vector2, sol_s: float) -> void:
	# Arriving in an afternoon already under way: its devils are running, not about to start.
	if _t == 0.0 and dt > 0.0:
		_t = 1e-6
		for i in int(LIFE[1] / 10.0): step(10.0, elev, wind, eye, sol_s)
	_t += dt
	var area := PI * FIELD_M * FIELD_M / 1e6
	# The day's devils packed into its hours of strong heating, about a quarter of a sol.
	_owed += RATE_KM2_SOL * scale * area * heating(elev) / (0.25 * maxf(sol_s, 3600.0)) * dt
	while _owed >= 1.0:
		_owed -= 1.0
		if devils.size() >= MAX: continue
		var r := FIELD_M * sqrt(_rng.randf())
		var a := _rng.randf() * TAU
		_next_id += 1
		devils.append({"id": _next_id, "at": eye + Vector2(cos(a), sin(a)) * r, "born": _t,
			"life": _rng.randf_range(LIFE[0], LIFE[1]),
			"d": exp(_rng.randf_range(log(DIAMETER[0]), log(DIAMETER[1]))),
			"h": _rng.randf_range(HEIGHT[0], HEIGHT[1]), "phase": _rng.randf() * TAU,
			"wander": Vector2(_rng.randf_range(-1.0, 1.0), _rng.randf_range(-1.0, 1.0))})
	for i in range(devils.size() - 1, -1, -1):
		var d: Dictionary = devils[i]
		d.at = (d.at as Vector2) + (wind + (d.wander as Vector2) * 0.8) * dt
		if _t - float(d.born) > float(d.life) or (d.at as Vector2).distance_to(eye) > FIELD_M * 1.3:
			devils.remove_at(i)

## How strong a devil is now, 0..1: it spins up and dies away.
func strength(d: Dictionary) -> float:
	var age := _t - float(d.born)
	return smoothstep(0.0, 40.0, age) * (1.0 - smoothstep(float(d.life) - 60.0, float(d.life), age))

## Draw them under `parent` (the site's group), in `tint` (sRGB, lit). `ground`: (east, north) -> the drawn
## height, m.
func draw(parent: Node3D, tint: Color, ground: Callable) -> void:
	if view == null:
		view = MultiMeshInstance3D.new()
		view.name = "dust_devils"
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.instance_count = MAX * PUFFS
		var quad := QuadMesh.new()
		var m := StandardMaterial3D.new()
		m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		m.billboard_keep_scale = true
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.vertex_color_use_as_albedo = true
		m.albedo_texture = PlumeDust._puff()
		m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
		# Unshaded: `tint` carries the day's light, a lit column of puffs being mostly forward and back scatter.
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		quad.material = m
		mm.mesh = quad
		view.multimesh = mm
		view.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		view.custom_aabb = AABB(Vector3(-1e4, -1e3, -1e4), Vector3(2e4, 4e3, 2e4))
		parent.add_child(view)
	var mm2 := view.multimesh
	var n := 0
	for d: Dictionary in devils:
		var s := strength(d)
		if s <= 0.0: continue
		var at: Vector2 = d.at
		var gy: float = ground.call(at.x, at.y)
		if is_nan(gy): continue
		var dia: float = d.d
		var h: float = d.h
		var spin := SWIRL / (dia * 0.5)
		for k in PUFFS:
			var f := (k + 0.5) / PUFFS
			# Packed at the foot, where the column is densest; it flares out and thins upward.
			var z := h * f * f
			var rad := dia * 0.5 * (1.0 + 1.8 * f * f)
			var ang := float(d.phase) + k * 2.39996 + spin * _t * (1.0 - 0.6 * f)
			var p := Vector3(-(at.x + cos(ang) * rad * 0.6), gy + z, at.y + sin(ang) * rad * 0.6)
			var size := rad * 2.2 + 6.0
			mm2.set_instance_transform(n, Transform3D(Basis.from_scale(Vector3.ONE * size), p))
			# Lifted dust is darker than the bright sky behind it and densest low down, which is how a column
			# stands out kilometres off in the rovers' frames.
			var a := s * 0.55 * pow(1.0 - f, 0.8)
			mm2.set_instance_color(n, Color(tint.r * 0.72, tint.g * 0.66, tint.b * 0.6, a))
			n += 1
	mm2.visible_instance_count = n

func dispose() -> void:
	if view != null and is_instance_valid(view): view.queue_free()
	view = null
	devils.clear()
