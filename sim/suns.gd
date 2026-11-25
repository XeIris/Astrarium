class_name Suns
extends RefCounted

# MULTI-SUN LIGHTING: the uniform block every star-facing surface declares
# (shaders/common/suns.gdshaderinc), fed by apply_suns(). Lighting is an array: a
# Trisolaran world has three terminators in three colours.

const MAX_SUNS := 4
const MAX_OCCLUDERS := 4

## Point every sun-aware material at the current star set (VisualCtx.Sun entries);
## `target_rel` is the lit body's camera-relative position. Directions come from two
## camera-relative positions, never absolute ones.
static func apply_suns(materials: Array, suns: Array, target_rel: Vector3) -> void:
	var n := mini(suns.size(), MAX_SUNS)
	var dirs := PackedVector3Array(); dirs.resize(MAX_SUNS)
	var cols := PackedVector3Array(); cols.resize(MAX_SUNS)
	var ints := PackedFloat32Array(); ints.resize(MAX_SUNS)
	for i in MAX_SUNS:
		dirs[i] = Vector3(1, 0, 0); cols[i] = Vector3(1, 1, 1); ints[i] = 0.0
	for i in n:
		var s: VisualCtx.Sun = suns[i]
		dirs[i] = (s.pos_rel - target_rel).normalized()
		cols[i] = Vector3(s.color.r, s.color.g, s.color.b)
		ints[i] = s.intensity
	for m in materials:
		if m == null: continue
		m.set_shader_parameter("uSunDir", dirs)
		m.set_shader_parameter("uSunColor", cols)
		m.set_shader_parameter("uSunInt", ints)
		m.set_shader_parameter("uSunCount", n)

## Feed the eclipse uniforms of `materials` for `body`: up to four other bodies, by
## the angular size they show from it, that could cover one of `suns`; true radii
## and positions (AU), in units of the body's own true radius. The star's angular
## radius as seen from the body rides along. `near` indexes `bodies` (VisualCtx.near).
static func apply_occluders(materials: Array, body: Body, bodies: Array, suns: Array, near: Neighbours = null) -> void:
	var r_self := maxf(body.radius, 1e-12)
	var occ := PackedVector4Array(); occ.resize(MAX_OCCLUDERS)
	var red := PackedFloat32Array(); red.resize(MAX_OCCLUDERS)
	var ang := PackedFloat32Array(); ang.resize(MAX_SUNS)
	var n_sun := mini(suns.size(), MAX_SUNS)
	var nearest_star := INF
	for i in n_sun:
		var star: Body = (suns[i] as VisualCtx.Sun).body
		if star == null or star == body: continue
		var d := star.pos.distance_to(body.pos)
		ang[i] = asin(minf(star.radius / maxf(d, 1e-12), 1.0))
		nearest_star = minf(nearest_star, d)
	var picks: Array = []
	if body.type in ["planet", "world", "gas-giant"]:
		picks = (near if near != null else Neighbours.new(bodies)).occluders(body, nearest_star, MAX_OCCLUDERS)
	var n := picks.size()
	for j in n:
		var b: Body = picks[j]
		var rel := b.pos.sub(body.pos).scaled(1.0 / r_self)
		occ[j] = Vector4(rel.x, rel.y, rel.z, b.radius / r_self)
		# A thick atmosphere bends sunset light into its umbra; Mars's is too thin.
		var air = Rocketry.ATMOSPHERES.get(b.name)
		red[j] = 1.0 if air != null and float(air.rho0) > 0.1 else 0.0
	for m in materials:
		if m == null: continue
		m.set_shader_parameter("uOcc", occ)
		m.set_shader_parameter("uOccRed", red)
		m.set_shader_parameter("uOccCount", n)
		m.set_shader_parameter("uSunAng", ang)

## Planetshine on `body`: the sunlit neighbour that lights it most, as an extra light.
## A Lambert sphere of albedo A and radius R at distance d gives the fraction
## A·(2/3)·(R/d)²·[sin α + (π − α)cos α]/π of the sunlight, α its phase angle (full
## Earth on the Moon: 7e-5). Drawn ×SHINE_GAIN, as the eclipse umbra's red is.
const SHINE_GAIN := 100.0
static func apply_shine(materials: Array, body: Body, bodies: Array, suns: Array, near: Neighbours = null) -> void:
	var best := 0.0
	var dir := Vector3(1, 0, 0)
	var col := Vector3(1, 1, 1)
	var s: VisualCtx.Sun = suns[0] if not suns.is_empty() else null
	if s != null and s.body != null and body.type in ["planet", "world"]:
		var lit: Array = (near if near != null else Neighbours.new(bodies)).shine(body, s.body)
		var b: Body = lit[0]
		if b != null:
			best = lit[1]
			dir = b.pos.sub(body.pos).to_v3().normalized()
			var c = b.spec.get("color")
			var lc: Color = U.lin(int(c)) if c != null else Color(0.8, 0.85, 1.0)
			col = Vector3(lc.r, lc.g, lc.b) * s.intensity * Vector3(s.color.r, s.color.g, s.color.b)
	for m in materials:
		if m == null: continue
		m.set_shader_parameter("uShineDir", dir)
		m.set_shader_parameter("uShineColor", col)
		m.set_shader_parameter("uShineInt", best * SHINE_GAIN)

## The geometric albedo planetshine assumes for a neighbour.
static func shine_albedo(b: Body) -> float:
	return float(U.nz(b.spec.get("albedo"), Rocketry.SURFACES.get(b.name, {}).get("albedo", 0.3)))

## The planetshine fraction above for a neighbour of radius `r` at distance `d`, with
## k = A·2/3 and `cos_phase` the cosine of its phase angle seen from the lit body.
static func shine_fraction(k: float, r: float, d: float, cos_phase: float) -> float:
	var alpha := acos(clampf(cos_phase, -1.0, 1.0))
	return k * pow(r / maxf(d, 1e-12), 2.0) * (sin(alpha) + (PI - alpha) * cos(alpha)) / PI

## Total insolation at a body in solar constants: S = Σ L_i / d_i² (L☉, AU), the
## quantity climate.gd integrates, so any planet knows its own temperature.
static func insolation_at(body: Body, suns: Array) -> float:
	if suns == null or suns.is_empty(): return 0.0
	var S := 0.0
	for s: VisualCtx.Sun in suns:
		var star: Body = s.body
		if star == null or star == body: continue
		var L: float = U.nz(star.luminosity, 1.0)
		var d := maxf(star.pos.distance_to(body.pos), 1e-4)
		S += L / (d * d)
	return S

# The light in a starless scene: a modest stand-in with a disc's colour temperature
# so a body beside a black hole isn't a flat silhouette (the lens pass exports no
# disc luminosity). If one is ever derived, read it here.
static func lit_by(ctx: VisualCtx):
	if not ctx.suns.is_empty(): return ctx.suns
	if ctx.holes.is_empty(): return null
	var near: VisualCtx.Hole = ctx.holes[0]
	return [VisualCtx.Sun.stand_in(near.pos_rel, U.lin(0xffd2a0), 1.2)]
