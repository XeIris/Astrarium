class_name Suns
extends RefCounted

# MULTI-SUN LIGHTING: the uniform block every star-facing surface declares
# (shaders/common/suns.gdshaderinc), fed by apply_suns(). Lighting is an array: a
# Trisolaran world has three terminators in three colours.

const MAX_SUNS := 4

## Point every sun-aware material at the current star set. `suns` entries:
## { pos_rel: Vector3 (camera-relative), color: Color (linear), intensity: float };
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
		dirs[i] = (suns[i].pos_rel - target_rel).normalized()
		var c: Color = suns[i].color
		cols[i] = Vector3(c.r, c.g, c.b)
		ints[i] = suns[i].intensity
	for m in materials:
		if m == null: continue
		m.set_shader_parameter("uSunDir", dirs)
		m.set_shader_parameter("uSunColor", cols)
		m.set_shader_parameter("uSunInt", ints)
		m.set_shader_parameter("uSunCount", n)

## Total insolation at a body in solar constants: S = Σ L_i / d_i² (L☉, AU), the
## quantity climate.gd integrates, so any planet knows its own temperature.
static func insolation_at(body: Body, suns: Array) -> float:
	if suns == null or suns.is_empty(): return 0.0
	var S := 0.0
	for s in suns:
		var star: Body = s.body
		if star == null or star == body: continue
		var L: float = U.nz(star.luminosity, 1.0)
		var d := maxf(star.pos.distance_to(body.pos), 1e-4)
		S += L / (d * d)
	return S

# The light in a starless scene: a modest stand-in with a disc's colour temperature
# so a body beside a black hole isn't a flat silhouette (the lens pass exports no
# disc luminosity). If one is ever derived, read it here.
static func lit_by(ctx: Dictionary):
	if ctx.has("suns") and not ctx.suns.is_empty(): return ctx.suns
	if not ctx.has("holes") or ctx.holes.is_empty(): return null
	var near: Dictionary = ctx.holes[0]
	return [{"pos_rel": near.pos_rel, "color": U.lin(0xffd2a0), "intensity": 1.2}]
