class_name Suns
extends RefCounted

# ============================================================================
# MULTI-SUN LIGHTING — the uniform block every surface in the orrery is lit by.
# ----------------------------------------------------------------------------
# A body here is never lit by "the" sun: a Trisolaran world has three
# terminators crossing its disc at once, in three different colours, and a
# circumbinary planet has two. So lighting is an ARRAY, and every material
# that faces a star declares the same block (shaders/common/suns.gdshaderinc)
# and is fed by the same apply_suns().
#
# It lives in its own module because both the solid-surface shaders
# (sim/rocky_visual.gd, sim/world.gd) and the gas giant (sim/giant_visual.gd)
# need it, and none of them should have to import each other to get it.
# ============================================================================

const MAX_SUNS := 4

## Point every sun-aware material at the current star set. `suns` entries carry
## { pos_rel: Vector3 (camera-relative scene position), color: Color (linear),
## intensity: float }; `target_rel` is the lit body's camera-relative position.
## Directions are formed from two camera-relative positions — never from
## absolute ones (PORT_GUIDE.md, floating origin).
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

## Total insolation at a body, in solar constants (S_Earth = 1), summed over
## every star: S = sum L_i / d_i^2 with L in solar luminosities and d in AU.
## This is the same quantity sim/climate.gd integrates, computed for a body
## that has no climate model of its own — which is what lets an ordinary planet
## know its own temperature, and therefore where its ice line and its deserts
## are, without anything being written down per preset.
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

# The light in a scene that has no stars in it. A black hole's accretion disc
# is the brightest thing in the universe per unit mass, so a planet beside one
# is lit — but by WHAT is not something this model knows: the lens pass draws
# a Shakura-Sunyaev disc without ever exporting a luminosity from it. So this
# is a deliberately modest stand-in with a disc's colour temperature rather
# than a derived flux, and its only job is to stop a body next to a black hole
# rendering as a flat silhouette. If a disc luminosity is ever derived, this is
# the one place that should read it.
static func lit_by(ctx: Dictionary):
	if ctx.has("suns") and not ctx.suns.is_empty(): return ctx.suns
	if not ctx.has("holes") or ctx.holes.is_empty(): return null
	var near: Dictionary = ctx.holes[0]
	return [{"pos_rel": near.pos_rel, "color": U.lin(0xffd2a0), "intensity": 1.2}]
