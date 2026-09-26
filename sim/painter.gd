class_name Painter
extends RefCounted

# ============================================================================
# PAINTER — rings, belts and clouds
# ----------------------------------------------------------------------------
# Everything here is made of enormous numbers of small things, which is exactly
# the case the N-body integrator cannot take: a ring is 10^13 particles, and
# even a token 20 000 of them would swamp an O(n²) force loop that is currently
# running twelve bodies.
#
# So these are TEST PARTICLES. Each one carries its own orbital elements and is
# advanced analytically in the central body's potential — mean anomaly grows at
# n = √(GM/a³), Kepler's equation is solved for the true position — rather than
# being integrated. That is not a cheat so much as a different and, here, more
# accurate method: for a particle whose own mass is negligible, the two-body
# solution IS the exact answer, and it neither drifts nor needs a step size.
# What it gives up is the particles' effect on each other and on the planet,
# which for a ring is genuinely negligible, and their response to a third body,
# which is not — so resonances are put in by hand where they matter (below).
#
# WHAT DECIDES WHERE A RING CAN BE. A ring is not a design choice. Inside the
# Roche limit,
#
#     d = 2.44 R_p (ρ_p/ρ_m)^⅓
#
# tidal forces across a body held together only by its own gravity exceed its
# self-gravity, so it cannot accrete into a moon and stays a ring; outside it,
# the same material collects into moons within a few orbits. Every ring in the
# solar system lies inside its planet's Roche limit and every major moon lies
# outside. So `ring_span()` returns that interval, and the painter defaults to
# it rather than to an arbitrary radius.
#
# KIRKWOOD GAPS. The asteroid belt is not uniform: it has gaps at the orbital
# radii where a particle's period is a simple ratio of Jupiter's, because a
# particle there gets the same kick at the same phase every time and its
# eccentricity is pumped until it crosses a planet and is removed. The 3:1,
# 5:2, 7:3 and 2:1 resonances are all visible in the real distribution, and
# they are what `_in_resonance_gap` reproduces — by depopulating those radii,
# which is what the dynamics does over the age of the solar system.
#
# PORT NOTES
#   · The Kepler solution runs in the VERTEX SHADER (shaders/bodies/
#     painter_swarm.gdshader), not on the CPU per frame: a GDScript loop over
#     26 000 particles is tens of milliseconds, a vertex shader is nothing.
#     The elements are attributes; the clock is a uniform split in two so the
#     float32 phase does not step (the shader header explains the split).
#   · THE FLOATING ORIGIN. Particle positions are relative to the item's
#     group, and the group is placed at its body's scene position minus the
#     camera's, in double: `place(cam_pos)` does that. Call update(sim_dt)
#     with the physics and place(cam_pos) once the camera is final, or
#     update(sim_dt, cam_pos) to do both.
# ============================================================================

const SWARM_SHADER := preload("res://shaders/bodies/painter_swarm.gdshader")
const CLOUD_SHADER := preload("res://shaders/bodies/painter_cloud.gdshader")

const TWO_PI := PI * 2.0

# Bulk densities, g/cm³ → kg/m³, for the Roche calculation.
const RHO := {"rock": 3000.0, "ice": 900.0, "rubble": 1500.0}

# ----------------------------------------------------------------------------
# The interval a ring can occupy around a body: from just above its surface out
# to the Roche limit for the given material.
#   radius_au  the central body's radius
#   mass_sun   its mass
# Returns { inner, outer, roche } in AU. `outer` is null when the Roche limit
# falls inside the body itself — which happens for a low-density central body,
# and means it simply cannot have a ring.
# ----------------------------------------------------------------------------
static func ring_span(mass_sun: float, radius_au: float, material := "ice") -> Dictionary:
	var M_SUN := 1.98892e30
	var rM := radius_au / Physics.AU_PER_KM * 1000.0
	var rhoP := (mass_sun * M_SUN) / ((4.0 / 3.0) * PI * rM * rM * rM)
	var roche := 2.44 * radius_au * U.cbrt(rhoP / float(RHO[material]))
	return {
		"inner": radius_au * 1.2,
		"outer": roche if roche > radius_au * 1.3 else null,
		"roche": roche,
	}

# The low-order mean-motion resonances that actually clear gaps, as the ratio
# of the perturber's period to the particle's.
const RESONANCES := [
	{"p": 3, "q": 1, "w": 0.012},   # 3:1  — the Hecuba gap, and the Cassini division's analogue
	{"p": 5, "q": 2, "w": 0.008},
	{"p": 7, "q": 3, "w": 0.006},
	{"p": 2, "q": 1, "w": 0.014},
]

# True where a semi-major axis sits inside a resonance gap with a perturber of
# semi-major axis a_pert.
static func _in_resonance_gap(a: float, a_pert: float) -> bool:
	for r in RESONANCES:
		# a_res / a_pert = (q/p)^(2/3)  from Kepler's third law
		var a_res := a_pert * pow(float(r.q) / float(r.p), 2.0 / 3.0)
		if absf(a - a_res) < float(r.w) * a_pert:
			return true
	return false

## Split x into (hi, lo) with hi carrying 12 significant bits, so that the
## product of two such "hi" parts is exact in float32 (see the swarm shader).
static func split12(x: float) -> Vector2:
	if x == 0.0 or not is_finite(x):
		return Vector2(0.0, 0.0)
	var e := floorf(log(absf(x)) / log(2.0))
	var q := pow(2.0, e - 11.0)
	var hi := floorf(x / q) * q
	return Vector2(hi, x - hi)

# ============================================================================
# The particle system itself. One point mesh, one draw call, the analytic
# solution evaluated per vertex.
# ============================================================================
static func particle_material(color, size_px: float, softness := 1.0) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = SWARM_SHADER
	m.set_shader_parameter("uColor", RockyVisual.v3(RockyVisual.lin_of(color)))
	m.set_shader_parameter("uSize", size_px)
	m.set_shader_parameter("uSoft", softness)
	return m

# ----------------------------------------------------------------------------
# create_orbital_swarm — the shared engine behind rings and belts. Options
# (the web build's names):
#
#   centralMass   M☉, the body the particles orbit
#   inner/outer   AU
#   count         number of particles
#   ecc/incl      maximum eccentricity and inclination spread
#   perturberA    if given, clear resonance gaps against a body at this a (AU)
#   sceneScale    scene units per AU
#   color sizePx tilt softness surfaceDensity shade
# ----------------------------------------------------------------------------
static func create_orbital_swarm(o: Dictionary) -> OrbitalSwarm:
	return OrbitalSwarm.new(o)

class OrbitalSwarm extends RefCounted:
	var group: Node3D
	var points: MeshInstance3D
	var mat: ShaderMaterial
	var count: int = 0
	var kind := ""
	var body_id = null
	var label := ""
	var orphan := false
	var t := 0.0          # years, double
	var scene_scale := 1.0
	var _extent := 1.0

	func _init(o: Dictionary) -> void:
		var central_mass := float(o.get("centralMass", 1.0))
		var inner := float(o.inner)
		var outer := float(o.outer)
		var N := maxi(16, int(U.nz(o.get("count"), 4000)))
		var ecc := float(U.nz(o.get("ecc"), 0.002))
		var incl := float(U.nz(o.get("incl"), 0.0008))
		var color = U.nz(o.get("color"), 0xcdbb99)
		var size_px := float(U.nz(o.get("sizePx"), 2.2))
		scene_scale = float(U.nz(o.get("sceneScale"), 1.0))
		var tilt := float(U.nz(o.get("tilt"), 0.0))
		var softness := float(U.nz(o.get("softness"), 1.0))
		var perturber_a = o.get("perturberA")
		var surface_density := float(U.nz(o.get("surfaceDensity"), -1.5))
		var shade: Array = U.nz(o.get("shade"), [0.55, 1.0])

		# Orbital elements, one set per particle, packed straight into the
		# vertex attributes the shader solves Kepler's equation from.
		var c0 := PackedFloat32Array()
		var c1 := PackedFloat32Array()
		var c2 := PackedFloat32Array()
		var GM := Physics.G * maxf(central_mass, 1e-9)
		var written := 0
		var guard := 0
		while written < N and guard < N * 40:
			guard += 1
			# Sample the semi-major axis from a power-law surface density Σ ∝ a^p,
			# so the number of particles between a and a+da goes as 2πa·Σ·da ∝ a^(p+1).
			# Saturn's rings and the asteroid belt are both centrally concentrated;
			# a flat sample would put most of the particles in the outer edge, which
			# is where a uniform random radius always puts them.
			var u := randf()
			var k := surface_density + 2.0
			var a: float
			if k == 0.0:
				a = inner * pow(outer / inner, u)
			else:
				a = pow(pow(inner, k) + u * (pow(outer, k) - pow(inner, k)), 1.0 / k)
			if perturber_a != null and float(perturber_a) != 0.0 and Painter._in_resonance_gap(a, float(perturber_a)):
				continue

			written += 1
			var e := randf() * ecc
			var inc := (randf() - 0.5) * 2.0 * incl
			var Om := randf() * TWO_PI
			var w := randf() * TWO_PI
			# mean motion, rad/yr → revolutions/yr, split for the float32 clock
			var nu := sqrt(GM / (a * a * a)) / TWO_PI
			var ns := Painter.split12(nu)
			var M0 := randf() * TWO_PI
			c0.append_array([a, e, ns.x, ns.y])
			c1.append_array([M0, inc, Om, w])
			c2.append_array([0.55 + randf() * 0.9, float(shade[0]) + randf() * (float(shade[1]) - float(shade[0])), 0.0, 0.0])
		count = written
		_extent = outer * (1.0 + ecc) * 1.05

		var verts := PackedVector3Array(); verts.resize(written)
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = verts
		arr[Mesh.ARRAY_CUSTOM0] = c0
		arr[Mesh.ARRAY_CUSTOM1] = c1
		arr[Mesh.ARRAY_CUSTOM2] = c2
		var fmt := (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT) \
				| (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT) \
				| (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM2_SHIFT)
		var mesh := ArrayMesh.new()
		if written > 0:
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_POINTS, arr, [], {}, fmt)
		mat = Painter.particle_material(color, size_px, softness)
		points = RockyVisual.mesh_instance(mesh, mat)
		points.name = "Swarm"

		group = Node3D.new()
		group.name = "OrbitalSwarm"
		group.add_child(points)
		group.rotation.x = tilt
		update(0.0, scene_scale)

	func update(sim_dt: float, scale = null) -> void:
		t += sim_dt
		if scale != null:
			scene_scale = float(scale)
		var ts := Painter.split12(t)
		mat.set_shader_parameter("uT", ts)
		mat.set_shader_parameter("uScale", scene_scale)
		# The positions are made in the shader, so the culling box has to be
		# stated: the whole annulus, out of the plane by the widest inclination.
		var ext := _extent * scene_scale
		points.custom_aabb = AABB(Vector3(-ext, -ext, -ext), Vector3(ext, ext, ext) * 2.0)

	func dispose() -> void:
		if is_instance_valid(group):
			group.queue_free()

# ============================================================================
# GAS CLOUD — an expanding shell, optionally bipolar.
# ----------------------------------------------------------------------------
# Nebulae are optically thin, so what you see is the integral of emission along
# the line of sight — which is why a hollow expanding shell looks like a bright
# RIM: the sightline through the edge passes through far more gas than the one
# through the middle. That limb brightening is the single feature that makes a
# shell read as a shell, and it is one line of shader (the exponent on the
# fresnel term) rather than a texture.
#
# Ejected shells also expand homologously — a parcel thrown out faster is
# further out, so v ∝ r and the whole thing scales without changing shape. The
# radius here therefore grows linearly with time at the speed given, which for
# Eta Carinae's Homunculus is a measured 650 km/s.
#
# Options: radius (AU), color, lobes, density, expandAUperYr, sceneScale, seed.
# ============================================================================
static func create_gas_cloud(o: Dictionary) -> GasCloud:
	return GasCloud.new(o)

class GasCloud extends RefCounted:
	var group: Node3D
	var mat: ShaderMaterial
	var shells: Array = []
	var kind := ""
	var body_id = null
	var label := ""
	var orphan := false
	var radius := 10.0
	var expand := 0.0
	var scene_scale := 1.0
	var r := 10.0          # current radius, AU (the web build's radiusAU getter)
	var t := 0.0

	func _init(o: Dictionary) -> void:
		radius = float(U.nz(o.get("radius"), 10.0))
		expand = float(U.nz(o.get("expandAUperYr"), 0.0))
		scene_scale = float(U.nz(o.get("sceneScale"), 1.0))
		mat = ShaderMaterial.new()
		mat.shader = Painter.CLOUD_SHADER
		mat.set_shader_parameter("uColor", RockyVisual.v3(RockyVisual.lin_of(U.nz(o.get("color"), 0xffcf9a))))
		mat.set_shader_parameter("uDensity", float(U.nz(o.get("density"), 0.7)))
		mat.set_shader_parameter("uTime", 0.0)
		mat.set_shader_parameter("uSeed", float(U.nz(o.get("seed"), 1.0)))
		# The web build gave the cloud's group renderOrder -2: among transparent
		# objects it draws first. render_priority is the same sort key here.
		mat.render_priority = -2

		group = Node3D.new()
		group.name = "GasCloud"
		# A bipolar cloud is two lobes thrown along the rotation axis — which is what
		# happens whenever the ejection is collimated by rotation or by a companion,
		# and is why the Homunculus is an hourglass and not a sphere.
		var n := maxi(1, int(U.nz(o.get("lobes"), 1)))
		var geo := RockyVisual.sphere_geometry(1.0, 48, 36)
		for i in n:
			var m := RockyVisual.mesh_instance(geo, mat)
			if n > 1:
				m.position.y = (1.0 if i == 0 else -1.0) * 0.85
				m.scale = Vector3(0.78, 1.0, 0.78)
			group.add_child(m)
			shells.append(m)
		update(0.0, scene_scale)

	func update(sim_dt: float, scale = null) -> void:
		t += sim_dt
		if scale != null:
			scene_scale = float(scale)
		mat.set_shader_parameter("uTime", t)
		r = radius + expand * t
		var s := maxf(r * scene_scale, 1e-12)
		group.scale = Vector3(s, s, s)

	func dispose() -> void:
		if is_instance_valid(group):
			group.queue_free()

# ============================================================================
# The painter's own bookkeeping: a list of decorations, each pinned to a body
# (or to the scene origin), updated together and disposed together.
#
#   Painter.create_painter({get_body: Callable(id) -> Body,
#                           get_scene_scale: Callable() -> float,
#                           root: Node3D})
# ============================================================================
static func create_painter(o: Dictionary) -> Painter:
	return Painter.new(o)

var items: Array = []
var _get_body: Callable
var _get_scene_scale: Callable
var _root: Node3D

func _init(o: Dictionary = {}) -> void:
	_get_body = o.get("get_body", Callable())
	_get_scene_scale = o.get("get_scene_scale", Callable())
	_root = o.get("root")

func _scale() -> float:
	return float(_get_scene_scale.call()) if _get_scene_scale.is_valid() else 1.0

## kind: "ring" | "belt" | "cloud". opts: the web build's option names, plus
## bodyId (pin to that body) and label.
func add(kind: String, opts: Dictionary):
	var o := opts.duplicate()
	o["sceneScale"] = _scale()
	var it
	if kind == "cloud":
		it = GasCloud.new(o)
	else:
		it = OrbitalSwarm.new(o)
	it.kind = kind
	it.body_id = opts.get("bodyId")
	it.label = str(U.nz(opts.get("label"), kind))
	if _root != null:
		_root.add_child(it.group)
	items.append(it)
	return it

## Advance every decoration by the simulated time actually integrated this
## frame, and drop any whose body is gone. Pass cam_pos to also place them.
func update(sim_dt: float, cam_pos: DVec3 = null) -> void:
	var scale := _scale()
	for it in items:
		it.update(sim_dt, scale)
		# Pinned decorations follow their body. A ring is bound to its planet,
		# so it has to travel with it — including through the planet's own orbit.
		if it.body_id != null:
			var b = _get_body.call(it.body_id) if _get_body.is_valid() else null
			# Gone OR dead: a body marked !alive has already lost its meshes, and
			# leaving the decoration pinned to its last position leaves a ring
			# around nothing.
			if b == null or not b.alive:
				it.orphan = true
	# A decoration whose body is gone goes with it.
	for i in range(items.size() - 1, -1, -1):
		if items[i].orphan:
			remove(items[i])
	if cam_pos != null:
		place(cam_pos)

## THE FLOATING ORIGIN: put every group at its body's absolute scene position
## minus the camera's, subtracted in double (PORT_GUIDE.md §3). Unpinned
## decorations sit at the scene origin. Call once the frame's camera is final.
func place(cam_pos: DVec3) -> void:
	for it in items:
		var p := DVec3.new()
		if it.body_id != null and _get_body.is_valid():
			var b = _get_body.call(it.body_id)
			if b != null and b.alive:
				p = b.scene_pos
		it.group.position = p.rel_v3(cam_pos)

func remove(it) -> void:
	var i := items.find(it)
	if i < 0: return
	items.remove_at(i)
	it.dispose()

func clear() -> void:
	while not items.is_empty():
		remove(items[0])
