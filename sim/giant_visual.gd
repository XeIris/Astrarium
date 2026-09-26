class_name GiantVisual
extends RefCounted

# ============================================================================
# GAS GIANTS
# ----------------------------------------------------------------------------
# A gas giant has no surface. What you are looking at is the top of a cloud
# deck a few bars down in an envelope thousands of kilometres deep, and the
# one thing that makes it read as GAS rather than as a painted ball is that it
# does not turn as one object:
#
#   · The interior rotates rigidly, because it is conducting and the magnetic
#     field ties it together. That rate — System III, 9h55m29.7s for Jupiter —
#     is the mesh's own rotation here, and it is the only thing the "core"
#     does.
#   · The visible atmosphere does NOT rotate at that rate. It is organised
#     into a dozen alternating zonal jets, and the equatorial one runs 100 m/s
#     FASTER than the interior while jets a few degrees away run slower. So
#     the cloud field is advected, in the shader, by
#         dlambda(phi) = [u(phi) / (R cos phi)] * t
#     and because that is a function of latitude, adjacent bands SHEAR past
#     each other. Everything that makes Jupiter look alive follows from that
#     one line: the ragged, filamented band edges, the way a vortex is drawn
#     out into an oval, the fact that a feature you were watching has drifted
#     relative to the one beside it a few hours later.
#   · Belts and zones are not stripes of paint either. The jets sit at their
#     BOUNDARIES — the flow is 90 degrees out of phase with the vertical
#     motion — so bright zones are rising ammonia-ice cloud and dark belts are
#     subsiding, cleared air where you are seeing several scale heights deeper
#     into warmer, browner chromophores. One phase function gives both.
#   · There are three optical levels, not one: a deep, warm layer, the main
#     deck, and a thin high haze, each advected at its own rate (the wind
#     shears with depth as well as with latitude) and composited by optical
#     depth. That is what stops the disc looking like a decal.
#
# The poles are deliberately NOT banded. Juno found the jets break down inside
# about 60 degrees latitude into a crowd of packed cyclones, which is why the
# polar view of Jupiter looks nothing like the equatorial one.
#
# Shaders: shaders/bodies/giant_body.gdshader (the deck, the flow map, the
# vortices, the ring shadow), giant_limb.gdshader (the limb haze) and
# ring_system.gdshader (the rings' optical-depth profile).
# ============================================================================

const BODY_SHADER := preload("res://shaders/bodies/giant_body.gdshader")
const LIMB_SHADER := preload("res://shaders/bodies/giant_limb.gdshader")
const RING_SHADER := preload("res://shaders/bodies/ring_system.gdshader")

const MAX_VORTEX := 6

# zone (rising, bright), belt (sinking, dark), deep (what you see down the
# holes), haze (the thin upper layer over everything). Hex values are sRGB,
# converted to linear where they reach a shader (U.lin), as THREE.Color did.
const GIANT_PALETTES := {
	# Jupiter has about six alternating jets per hemisphere, so uJets is set so
	# that sin(uJets * lat) completes that many half cycles between equator and
	# pole; jetAmp and eqJet are in the same units as the advection rate.
	"jupiter": {"zone": 0xc2b190, "belt": 0x7d5233, "deep": 0x54301e, "haze": 0xb5a68c, "spot": 0xa5522f,
			"jets": 11.0, "jetAmp": 0.55, "contrast": 1.0, "eqJet": 1.0},
	"saturn":  {"zone": 0xcfbf96, "belt": 0xa88b5e, "deep": 0x876236, "haze": 0xd2c6aa, "spot": 0xb59868,
			"jets": 8.5, "jetAmp": 0.35, "contrast": 0.50, "eqJet": 2.6},
	"ice":     {"zone": 0x8ec6d6, "belt": 0x4f8cb6, "deep": 0x27608f, "haze": 0xaad8e4, "spot": 0x21406f,
			"jets": 4.5, "jetAmp": 0.30, "contrast": 0.22, "eqJet": -0.8},
}

# ---------------------------------------------------------------------------
# The zonal wind profile — the GDScript twin of zonalWind() in the shader, so
# a spot always travels at the speed of the jet it is sitting in.
# ---------------------------------------------------------------------------
static func zonal_wind(pal: Dictionary, lat: float) -> float:
	var a := absf(lat)
	var env := exp(-pow(a / 1.05, 4.0))
	return float(pal.eqJet) * exp(-pow(a / 0.24, 2.0)) + float(pal.jetAmp) * cos(float(pal.jets) * lat) * env

## mulberry32 — the web build's seeded generator, bit for bit, so the vortices
## land where they land in the web build. JS does this in int32 with
## Math.imul; here every value is kept as an unsigned 32-bit int in a 64-bit
## one, and the multiply is split so no product exceeds 48 bits.
class Mulberry extends RefCounted:
	var a: int
	func _init(seed: int) -> void:
		a = seed & 0xFFFFFFFF
	static func imul(x: int, y: int) -> int:
		x &= 0xFFFFFFFF; y &= 0xFFFFFFFF
		var lo := x * (y & 0xFFFF)
		var hi := ((x * (y >> 16)) & 0xFFFF) << 16
		return (lo + hi) & 0xFFFFFFFF
	func next() -> float:
		a = (a + 0x6D2B79F5) & 0xFFFFFFFF
		var t := imul(a ^ (a >> 15), 1 | a)
		t = ((t + imul(t ^ (t >> 7), 61 | t)) & 0xFFFFFFFF) ^ t
		return float((t ^ (t >> 14)) & 0xFFFFFFFF) / 4294967296.0

# ---------------------------------------------------------------------------
# THREE.RingGeometry(inner, outer, thetaSegments, phiSegments) in its own XY
# plane (the shader reads the radius from the local position).
# ---------------------------------------------------------------------------
static func ring_geometry(inner: float, outer: float, tseg: int, pseg: int) -> ArrayMesh:
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var idx := PackedInt32Array()
	var step := (outer - inner) / float(pseg)
	for j in pseg + 1:
		var rr := inner + step * j
		for i in tseg + 1:
			var th := TAU * float(i) / float(tseg)
			verts.append(Vector3(rr * cos(th), rr * sin(th), 0.0))
			norms.append(Vector3(0, 0, 1))
	for j in pseg:
		var base := j * (tseg + 1)
		for i in tseg:
			var a := base + i
			var b := a + tseg + 1
			var c := a + tseg + 2
			var d := a + 1
			idx.append_array([a, d, b, b, d, c])
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return m

static func _giant_material(seed: float, pal: Dictionary) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = BODY_SHADER
	Suns.apply_suns([m], [], Vector3.ZERO)
	m.set_shader_parameter("uTime", 0.0)
	m.set_shader_parameter("uSeed", seed)
	m.set_shader_parameter("uZone", RockyVisual.v3(U.lin(int(pal.zone))))
	m.set_shader_parameter("uBelt", RockyVisual.v3(U.lin(int(pal.belt))))
	m.set_shader_parameter("uDeep", RockyVisual.v3(U.lin(int(pal.deep))))
	m.set_shader_parameter("uHaze", RockyVisual.v3(U.lin(int(pal.haze))))
	m.set_shader_parameter("uContrast", float(pal.contrast))
	m.set_shader_parameter("uJets", float(pal.jets))
	m.set_shader_parameter("uJetAmp", float(pal.jetAmp))
	m.set_shader_parameter("uEqJet", float(pal.eqJet))
	m.set_shader_parameter("uTeff", 124.0)
	var vs := PackedVector4Array(); vs.resize(MAX_VORTEX)
	var vc := PackedVector3Array(); vc.resize(MAX_VORTEX)
	for i in MAX_VORTEX:
		vc[i] = RockyVisual.v3(U.lin(int(pal.spot)))
	m.set_shader_parameter("uVortex", vs)
	m.set_shader_parameter("uVortexCol", vc)
	m.set_shader_parameter("uVortexN", 0)
	# ring shadow cast ONTO the planet: inner/outer radius in body radii, 0 = none
	m.set_shader_parameter("uRingIn", 0.0)
	m.set_shader_parameter("uRingOut", 0.0)
	var so := PackedVector3Array(); so.resize(Suns.MAX_SUNS)
	for i in Suns.MAX_SUNS: so[i] = Vector3(1, 0, 0)
	m.set_shader_parameter("uSunObj", so)
	return m

static func _limb_material(pal: Dictionary) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = LIMB_SHADER
	Suns.apply_suns([m], [], Vector3.ZERO)
	m.set_shader_parameter("uTint", RockyVisual.v3(U.lin(int(pal.haze))))
	return m

static func _ring_material(opts: Dictionary, seed: float) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = RING_SHADER
	Suns.apply_suns([m], [], Vector3.ZERO)
	m.set_shader_parameter("uColor", RockyVisual.v3(RockyVisual.lin_of(U.nz(opts.get("ringColor"), 0xd8c9a6))))
	m.set_shader_parameter("uInner", float(U.nz(opts.get("ringInner"), 1.24)))
	m.set_shader_parameter("uOuter", float(U.nz(opts.get("ringOuter"), 2.27)))
	m.set_shader_parameter("uBodyR", 1.0)
	m.set_shader_parameter("uSeed", seed)
	var so := PackedVector3Array(); so.resize(Suns.MAX_SUNS)
	for i in Suns.MAX_SUNS: so[i] = Vector3(1, 0, 0)
	m.set_shader_parameter("uSunObj", so)
	return m

# ---------------------------------------------------------------------------
static func create_giant_visual(b: Body, opts: Dictionary = {}) -> GiantViz:
	return GiantViz.new(b, opts)

## The visual object (PORT_GUIDE.md §7). Fields mirror the web build's b.viz:
## group, core, body_mesh (JS `body`), limb, rings, mat, limb_mat, ring_mat,
## base_r, R, is_giant, vortices; plus update(dt, ctx).
class GiantViz extends RefCounted:
	var group: Node3D
	var core: MeshInstance3D
	var body_mesh: MeshInstance3D
	var limb: MeshInstance3D
	var rings: MeshInstance3D = null
	var mat: ShaderMaterial
	var limb_mat: ShaderMaterial
	var ring_mat: ShaderMaterial = null
	var base_r: float
	var R: float
	var is_giant := true
	## [{lat, lon, size, strength, color: Color}]
	var vortices: Array = []
	var body: Body
	var pal: Dictionary
	var albedo: float
	var internal: float
	var tilt_q := Quaternion()

	func _init(b: Body, opts: Dictionary) -> void:
		body = b
		group = Node3D.new()
		group.name = "Giant_%s" % b.name
		R = float(opts.get("radiusScene", 1.0))
		base_r = R
		var p = opts.get("giantPalette")
		if p == null:
			p = GiantVisual.GIANT_PALETTES.get(str(U.nz(opts.get("paletteName"), "jupiter")), GiantVisual.GIANT_PALETTES.jupiter)
		pal = (p as Dictionary).duplicate()
		var seed := float(RockyVisual.id_hash(b.id) % 997) / 5.9

		mat = GiantVisual._giant_material(seed, pal)
		body_mesh = RockyVisual.mesh_instance(RockyVisual.sphere_geometry(R, 96, 64), mat)
		body_mesh.name = "Body"
		group.add_child(body_mesh)
		core = body_mesh

		limb_mat = GiantVisual._limb_material(pal)
		limb = RockyVisual.mesh_instance(RockyVisual.sphere_geometry(R * 1.035, 48, 32), limb_mat)
		limb.name = "Limb"
		group.add_child(limb)

		# --- long-lived vortices. They sit where the shear is anticyclonic, which
		# is the poleward side of a prograde jet; the Great Red Spot has been at
		# 22 degrees south for at least 190 years for exactly that reason.
		var rnd := GiantVisual.Mulberry.new(int(seed * 1000.0 + 7.0))
		var contrast := float(pal.contrast)
		var nV := int(U.nz(opts.get("vortices"), 3 if contrast > 0.6 else (2 if contrast > 0.3 else 1)))
		var vscale := float(U.nz(opts.get("vortexScale"), 1.0))
		for i in mini(nV, GiantVisual.MAX_VORTEX):
			# pick a latitude at an anticyclonic phase of the jet system
			# (the JS evaluates these in object-literal order; so does this)
			var lat := -0.39 if i == 0 else (rnd.next() - 0.5) * 1.6
			var lon := rnd.next() * TAU
			var size := (0.135 if i == 0 else 0.045 + rnd.next() * 0.04) * vscale
			var strength := 0.85 if i == 0 else 0.45 + rnd.next() * 0.3
			var c0 := U.lin(int(pal.spot) if i == 0 else int(pal.zone))
			var col := c0.lerp(U.lin(int(pal.deep)), rnd.next() * 0.4)
			vortices.append({"lat": lat, "lon": lon, "size": size, "strength": strength, "color": col})
		mat.set_shader_parameter("uVortexN", vortices.size())
		var vc: PackedVector3Array = mat.get_shader_parameter("uVortexCol")
		for i in vortices.size():
			vc[i] = RockyVisual.v3(vortices[i].color)
		mat.set_shader_parameter("uVortexCol", vc)

		# --- rings
		if RockyVisual.truthy(opts.get("rings")):
			var inner := float(U.nz(opts.get("ringInner"), 1.24))
			var outer := float(U.nz(opts.get("ringOuter"), 2.27))
			# The visual radius is exaggerated along with the body, so the ring system
			# is built in BODY RADII and scaled with it — a ring is at a resonance
			# with a moon, not at an absolute distance.
			ring_mat = GiantVisual._ring_material(opts, seed)
			ring_mat.set_shader_parameter("uBodyR", R)
			rings = RockyVisual.mesh_instance(GiantVisual.ring_geometry(R * inner, R * outer, 192, 8), ring_mat)
			rings.name = "Rings"
			rings.rotation.x = -PI / 2.0
			group.add_child(rings)
			mat.set_shader_parameter("uRingIn", inner)
			mat.set_shader_parameter("uRingOut", outer)

		# Axial tilt. Rings are equatorial, so they are inside this group and tip
		# with it — which is the whole reason Saturn's rings open and close.
		var obl := float(U.nz(opts.get("obliquity"), 0.05))
		group.rotation.z = obl
		tilt_q = Quaternion(Vector3(0, 0, 1), obl)

		# System III: the rigid interior rate. Everything above moves relative to it.
		if b.spin == null:
			b.spin = 0.9 + randf() * 0.5
		albedo = float(U.nz(opts.get("albedo"), 0.5))
		# Internal heat: Jupiter radiates 1.67x what it absorbs, Saturn 1.78x, from
		# contraction and (on Saturn) helium rain. Neptune 2.6x; Uranus, oddly, ~1.
		internal = float(U.nz(opts.get("internalHeat"), 1.67))
		b.viz = self

	func update(dt: float, ctx: Dictionary) -> void:
		var b := body
		b.spin_phase = fmod(b.spin_phase + float(b.spin) * dt, TAU)
		body_mesh.rotation.y = b.spin_phase               # the core, and only the core
		mat.set_shader_parameter("uTime", float(mat.get_shader_parameter("uTime")) + dt)

		# Each vortex rides its own jet. Same profile the shader advects the cloud
		# with, so a spot never drifts out of the band it belongs to.
		var vs := PackedVector4Array(); vs.resize(GiantVisual.MAX_VORTEX)
		for i in vortices.size():
			var v: Dictionary = vortices[i]
			v.lon = fmod(float(v.lon) + (GiantVisual.zonal_wind(pal, v.lat) / maxf(cos(v.lat), 0.15)) * dt, TAU)
			vs[i] = Vector4(sin(v.lat), v.lon, v.size, v.strength)
		mat.set_shader_parameter("uVortex", vs)

		var suns = Suns.lit_by(ctx)
		if suns != null:
			var mats := [mat, limb_mat]
			if ring_mat != null: mats.append(ring_mat)
			Suns.apply_suns(mats, suns, group.position)
			# Effective temperature: what it absorbs plus what it makes.
			var real_suns: bool = ctx.has("suns") and ctx.suns != null and not ctx.suns.is_empty()
			var S: float = Suns.insolation_at(b, ctx.suns) if real_suns else float(suns[0].intensity)
			var Teq := 278.6 * pow(maxf(S, 1e-9) * (1.0 - albedo), 0.25)
			mat.set_shader_parameter("uTeff", Teq * pow(internal, 0.25))
			# Sun directions in the BODY frame, for the two shadow tests. The group
			# carries the axial tilt, so this is where the ring shadow learns which
			# way the rings are leaning.
			var inv := tilt_q.inverse()
			# The RING mesh is not spun, so the group frame is its frame. The BODY
			# mesh is: rotation.y carries System III, and its shader tests the ring
			# shadow against vObj, its own local position. Handing it the group-frame
			# direction leaves the two frames a spin phase apart, and the shadow then
			# travels round the planet at the interior rotation rate instead of
			# staying under the sunward side of the ring plane. Taken back out with
			# the mesh's own quaternion rather than a hand-written rotation, because
			# the sign of that is exactly the trap this is.
			var body_inv := body_mesh.quaternion.inverse()
			var n := mini(suns.size(), Suns.MAX_SUNS)
			var so_ring := PackedVector3Array(); so_ring.resize(Suns.MAX_SUNS)
			var so_body := PackedVector3Array(); so_body.resize(Suns.MAX_SUNS)
			for i in Suns.MAX_SUNS:
				so_ring[i] = Vector3(1, 0, 0); so_body[i] = Vector3(1, 0, 0)
			for i in n:
				var d: Vector3 = inv * (suns[i].pos_rel - group.position).normalized()
				so_ring[i] = d
				so_body[i] = body_inv * d
			if ring_mat != null: ring_mat.set_shader_parameter("uSunObj", so_ring)
			mat.set_shader_parameter("uSunObj", so_body)
