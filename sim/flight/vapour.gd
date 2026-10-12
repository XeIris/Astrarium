class_name Vapour
extends RefCounted

# Condensation collars: the fog that forms round a vehicle's shoulders near Mach 1 in
# humid air. Air turning a convex corner accelerates and cools; its water vapour is
# expanded with it, but saturation pressure falls far faster than the vapour's own,
# so past 100 % local humidity it condenses. It evaporates again at the shock that
# recompresses the flow, which is the collar's sharp aft edge.
# docs/physics/vapour.md has the derivation.

const GAMMA := 1.4
## Gas constant of water vapour, J/(kg·K).
const R_V := 461.5
## Extinction per kilogram of condensate, m²/kg. An expansion lasting milliseconds
## leaves no time to grow: droplets of ~0.3 µm, 3·Q / (4 ρ_w r) with Q ≈ 2.
const KAPPA := 5000.0
const ORDER := 15

## {y, r, theta, stage, node, mat} per shoulder, top first. `y` (craft frame, m) is the
## corner, `r` the body radius below it, `theta` the turn the flow makes, rad.
var shoulders: Array = []
var group: Node3D

## Measure the stack's shoulders from its meshes and hang a collar on each. Returns
## null for a vehicle without one.
static func create(craft: CraftModel.Craft) -> Vapour:
	var prof := radius_profile(craft, 96)
	var found := find_shoulders(prof.r, prof.dy, prof.stage)
	if found.is_empty(): return null
	var v := Vapour.new()
	v.group = Node3D.new()
	v.group.name = "vapour"
	craft.group.add_child(v.group)
	for s in found:
		var m := ShaderMaterial.new()
		m.shader = Plume.shader("vapour")
		m.render_priority = ORDER
		var mi := MeshInstance3D.new()
		mi.mesh = Plume._box_mesh()
		mi.material_override = m
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.position.y = s.y
		mi.visible = false
		v.group.add_child(mi)
		s.node = mi
		s.mat = m
		s.seed = randf() * 50.0
		v.shoulders.append(s)
	return v

## The stack's radius in `n` height bins from its meshes, in the craft frame:
## {r: PackedFloat64Array, dy, stage: Array (the key of the stage that sets each bin)}.
## Taken round eight sectors and then the second-narrowest of them, so fins, flaps and
## side-mounted boosters, which fill only some sectors, do not count as the body.
static func radius_profile(craft: CraftModel.Craft, n: int) -> Dictionary:
	const NS := 8
	var H := maxf(craft.height, 1.0)
	var dy := H / float(n)
	var sect := []
	var who := []
	for k in NS:
		var row := PackedFloat64Array(); row.resize(n)
		sect.append(row)
		var o := []; o.resize(n)
		who.append(o)
	for st: CraftModel.CraftStage in craft.stages:
		for mi in _meshes(st.group):
			var xf := _to(mi, craft.group)
			# This mesh alone, per sector; -1 where it has no vertex.
			var own := []
			for k in NS:
				var row := PackedFloat64Array(); row.resize(n); row.fill(-1.0)
				own.append(row)
			for si in mi.mesh.get_surface_count():
				var verts: PackedVector3Array = mi.mesh.surface_get_arrays(si)[Mesh.ARRAY_VERTEX]
				var stride := maxi(1, verts.size() / 30000)
				for k in range(0, verts.size(), stride):
					var p := xf * verts[k]
					var bi := int(p.y / dy)
					if bi < 0 or bi >= n: continue
					var sk := posmod(int(floor(atan2(p.z, p.x) / TAU * NS)), NS)
					var row: PackedFloat64Array = own[sk]
					row[bi] = maxf(row[bi], Vector2(p.x, p.z).length())
			# A cylinder's vertices are only at its ends: interpolate between them, which
			# is exact for a cylinder or a cone.
			for k in NS:
				var row: PackedFloat64Array = own[k]
				var last := -1
				for bi in n:
					if row[bi] < 0.0: continue
					if last >= 0 and bi - last > 1:
						for j in range(last + 1, bi):
							row[j] = lerpf(row[last], row[bi], float(j - last) / float(bi - last))
					last = bi
				var g: PackedFloat64Array = sect[k]
				for bi in n:
					if row[bi] > g[bi]:
						g[bi] = row[bi]
						who[k][bi] = st.key
				sect[k] = g
	var r := PackedFloat64Array(); r.resize(n)
	var owner := []; owner.resize(n)
	for bi in n:
		var vals := []
		for k in NS: vals.append([sect[k][bi], k])
		vals.sort_custom(func(x, y): return x[0] < y[0])
		r[bi] = vals[1][0]
		owner[bi] = who[vals[1][1]][bi]
	return {"r": r, "dy": dy, "stage": owner}

static func _meshes(n: Node) -> Array:
	var out := []
	for c in n.get_children():
		# The plumes hang under the gimbals; they are not the body.
		if c.name == "plume" or c.name == "vapour": continue
		if c is MeshInstance3D and (c as MeshInstance3D).mesh != null: out.append(c)
		out.append_array(_meshes(c))
	return out

static func _to(n: Node3D, root: Node3D) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var p: Node = n
	while p != null and p != root:
		if p is Node3D: xf = (p as Node3D).transform * xf
		p = p.get_parent()
	return xf

## Convex corners going down the stack: the foot of a rise of a fifth or more (a nose
## or a flare), and the top of a boat-tail, where the body narrows again. The lowest sixth (bells, skirts, fins) is
## skipped: the flow there is the base's, not a shoulder's.
static func find_shoulders(r: PackedFloat64Array, dy: float, owner: Array) -> Array:
	var n := r.size()
	var floor_b := n / 6
	var rmax := 0.0
	for i in range(floor_b, n): rmax = maxf(rmax, r[i])
	var out := []
	var b := n - 1
	while b > floor_b:
		if r[b] > 0.3 * rmax and r[b] > r[mini(b + 3, n - 1)] * 1.2:
			# Down to the corner, and up to where the rise began, for its angle.
			var c := b
			while c > floor_b + 1 and r[c - 1] > r[c] * 1.02: c -= 1
			var t := b
			while t < n - 1 and r[t + 1] < r[t] * 0.98 and r[t + 1] > 0.0: t += 1
			var theta := atan2(r[c] - r[t], float(t - c + 1) * dy)
			out.append({"y": (float(c) + 0.5) * dy, "r": r[c], "theta": clampf(theta, 0.08, 0.6), "stage": str(owner[c])})
			# One collar per corner, and none within two radii below it.
			b = c - maxi(3, int(2.0 * r[c] / dy))
			continue
		# A boat-tail: the body narrows again, and the flow turns in round its top.
		if r[b] > 0.3 * rmax and b - 3 > floor_b and r[b - 3] < r[b] * 0.85 and r[mini(b + 2, n - 1)] >= r[b] * 0.97:
			var e := b - 3
			while e > floor_b + 1 and r[e - 1] < r[e] * 0.98: e -= 1
			var theta := atan2(r[b] - r[e], float(b - e + 1) * dy)
			out.append({"y": (float(b) + 0.5) * dy, "r": r[e], "theta": clampf(theta, 0.08, 0.6), "stage": str(owner[b])})
			b = e - maxi(3, int(2.0 * r[e] / dy))
			continue
		b -= 1
	return out

## Saturation vapour pressure over water, Pa (Magnus, Alduchov–Eskridge).
static func e_sat(T: float) -> float:
	var c := T - 273.15
	return 611.2 * exp(17.62 * c / (243.12 + c))

## The Prandtl–Meyer function ν(M), rad.
static func pm_nu(M: float) -> float:
	if M <= 1.0: return 0.0
	var k := sqrt((GAMMA + 1.0) / (GAMMA - 1.0))
	var m2 := M * M - 1.0
	return k * atan(sqrt(m2) / k) - atan(sqrt(m2))

static func pm_mach(nu: float) -> float:
	var lo := 1.0; var hi := 12.0
	for i in 40:
		var mid := (lo + hi) * 0.5
		if pm_nu(mid) < nu: lo = mid
		else: hi = mid
	return (lo + hi) * 0.5

## Peak Mach over a corner turning the flow by `theta`: Prandtl–Glauert scaling of an
## incompressible pressure dip below Mach 1, a Prandtl–Meyer expansion above it,
## blended through the transonic gap.
static func local_mach(M: float, theta: float) -> float:
	var sub := 0.0
	if M < 1.05:
		# Cp ≈ −θ incompressible, ×1/√(1−M²) capped where the linear theory fails.
		var cp := -theta / sqrt(maxf(1.0 - minf(M, 0.98) * minf(M, 0.98), 0.25))
		var pr := maxf(1.0 + 0.5 * GAMMA * M * M * cp, 0.05)
		var p0 := pow(1.0 + 0.2 * M * M, 3.5)
		sub = sqrt(maxf(5.0 * (pow(p0 / pr, 1.0 / 3.5) - 1.0), 0.0))
	if M <= 0.98: return sub
	var sup := pm_mach(pm_nu(maxf(M, 1.0)) + theta)
	if M >= 1.05: return sup
	return lerpf(sub, sup, (M - 0.98) / 0.07)

## Water condensed in the expansion, kg/m³, from the freestream's Mach, temperature
## (K) and relative humidity (0..1), over a corner of `theta`.
static func condensate(M: float, T: float, rh: float, theta: float) -> float:
	if M < 0.3 or rh <= 0.0: return 0.0
	var Ml := local_mach(M, theta)
	var Tl := T * (1.0 + 0.2 * M * M) / (1.0 + 0.2 * Ml * Ml)
	# The vapour is compressed with the air: its pressure falls as p does.
	var e := rh * e_sat(T) * pow(Tl / T, 3.5)
	return maxf(e - e_sat(Tl), 0.0) / (R_V * Tl)

## Relative humidity at `alt`: the troposphere's, given; the stratosphere is dry.
static func humidity_at(rh: float, alt: float) -> float:
	return lerpf(rh, 0.03, smoothstep(9000.0, 13000.0, alt))

## @param o {mach, T (K), rh (0..1, at the ground's level), alt (m), time, attached
##   ({key: bool}), sun (toward the sun, in the craft's frame), light (Plume.daylight)}
func update(o: Dictionary) -> void:
	var M := float(o.mach)
	var rh := humidity_at(float(o.rh), float(o.alt))
	var attached: Dictionary = o.get("attached", {})
	# The collar's reach: the subsonic pocket grows toward Mach 1, the supersonic
	# expansion is a thin sheath ending at the next shock.
	var near1 := exp(-pow((M - 1.0) / 0.14, 2.0))
	for s in shoulders:
		var mi: MeshInstance3D = s.node
		var w := condensate(M, float(o.T), rh, float(s.theta))
		var sigma := w * KAPPA
		var R: float = s.r
		var on: bool = sigma * R > 0.01 and attached.get(s.stage, true) != false
		mi.visible = on
		if not on: continue
		var Lc := R * (1.4 + 3.2 * near1)
		var flare := 0.25 + 0.75 * near1
		var Rb := R * (1.0 + flare) * 1.15
		var m: ShaderMaterial = s.mat
		m.set_shader_parameter("uBox", Vector3(Rb, Lc, Rb))
		m.set_shader_parameter("uR", R)
		m.set_shader_parameter("uFlare", flare)
		m.set_shader_parameter("uSigma", sigma)
		m.set_shader_parameter("uTime", float(o.get("time", 0.0)))
		m.set_shader_parameter("uSeed", float(s.seed))
		m.set_shader_parameter("uSunDir", (o.get("sun", Vector3.UP) as Vector3).normalized())
		m.set_shader_parameter("uLight", float(o.get("light", 1.0)))
		mi.custom_aabb = AABB(Vector3(-Rb, -Lc, -Rb), Vector3(Rb * 2.0, Lc + R * 0.2, Rb * 2.0))

func dispose() -> void:
	if group != null and is_instance_valid(group): group.queue_free()
	shoulders.clear()
