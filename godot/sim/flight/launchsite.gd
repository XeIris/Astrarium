class_name LaunchSite
extends RefCounted

# ============================================================================
# THE LAUNCH COMPLEX — port of sim/flight/launchsite.js.
# ----------------------------------------------------------------------------
# A rocket rising over an empty plain does not look like it is rising. There is
# nothing in the frame whose size is known, so there is no parallax to read and
# no scale to read it against — the vehicle appears to sit still and then to be
# somewhere else. Every launch broadcast ever made solves this the same way: it
# puts a tower of known height next to the vehicle and lets you watch the
# vehicle go past it.
#
# So this is not decoration. The tower is the instrument you read the first
# fifteen seconds of a launch on, which is exactly the part of the flight where
# the vehicle is moving slowly enough that nothing else in view is changing.
#
# Everything here is at real dimensions, from the pads these vehicles actually
# flew from:
#
#   LC-39A hardstand      390 × 325 m octagon, raised 12.8 m above grade
#   flame trench          137 m long, 18 m wide, 12.2 m deep, split by a
#                         wedge deflector under the vehicle
#   Mobile Launcher       49.4 × 41.1 m platform, 7.6 m deep, one 13.7 m
#                         square exhaust opening
#   LUT (Saturn V)        115.8 m to the top of the hammerhead crane, 12 m
#                         square in plan, nine swing arms
#   FSS (Shuttle)         75.3 m, plus the vent arm and its "beanie cap" over
#                         the ET, and a rotating service structure
#   Falcon 9 TE           ~63 m strongback, retracted a few degrees at T−4 min
#                         and dropped away at liftoff
#   Starship tower        146 m, two catch arms
#   lightning masts       three, on a catenary; the 39B masts are 181 m
#   water tower           88 m, 1.135 Ml, for the sound suppression deluge
#
# The moving parts move for the reasons they really do: swing arms carry
# propellant and power and cannot be released until the engines are up, so they
# retract on ignition; the strongback is holding the vehicle vertical and falls
# back as it leaves; the deluge starts before ignition, because it is there to
# stop the ACOUSTIC energy reflecting off the deck and shaking the payload
# apart, not to cool anything.
#
# PORT NOTES
#   · Geometry goes through CraftModel's three-exact primitives (_box,
#     _cylinder, _circle, _sphere, _to_mesh) so the complex has three's
#     tessellation and winding; the strut soup and the crawlerway ribbon are
#     written in three's counter-clockwise order and swapped once by _to_mesh.
#   · MeshStandardMaterial → StandardMaterial3D with three's BRDF (Lambert
#     diffuse, Schlick-GGX, F0 0.04), front-sided as three's default is.
#   · decal()'s polygonOffset → shaders/flight/decal.gdshader (see there).
#   · THREE.Points for the deluge → a PRIMITIVE_POINTS ArrayMesh rebuilt each
#     frame from the live particles (shaders/flight/steam.gdshader).
#   · Every node's Euler order is XYZ, three's, so rotation.y/z mean what the
#     JS wrote.
# ============================================================================

static var _mats := {}
static func _std(name: String, hex: int, rough: float, metal: float) -> StandardMaterial3D:
	if _mats.has(name): return _mats[name]
	var m := StandardMaterial3D.new()
	m.resource_name = name
	m.albedo_color = Color.hex((hex << 8) | 0xff)
	m.roughness = rough
	m.metallic = metal
	m.metallic_specular = 0.5
	m.diffuse_mode = BaseMaterial3D.DIFFUSE_LAMBERT
	m.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX
	_mats[name] = m
	return m

static func CONCRETE() -> StandardMaterial3D: return _std("concrete", 0x8d8d88, 0.95, 0.02)
static func DARKCON() -> StandardMaterial3D: return _std("darkcon", 0x5c5c58, 0.96, 0.02)
static func STEEL() -> StandardMaterial3D: return _std("steel", 0x7a8288, 0.62, 0.55)
static func PAINT() -> StandardMaterial3D: return _std("paint", 0x9c3f2e, 0.8, 0.1)
static func GREY() -> StandardMaterial3D: return _std("grey", 0x6e7276, 0.75, 0.35)
static func SCORCH() -> StandardMaterial3D: return _std("scorch", 0x2a2724, 0.98, 0.02)
static func WHITE() -> StandardMaterial3D: return _std("white", 0xc9ccd0, 0.8, 0.08)

# ---------------------------------------------------------------------------
# A DECAL IS NOT A SLAB LIFTED A FEW CENTIMETRES — see decal.gdshader. The
# materials are separate rather than flagged in place because the same
# concrete is structural elsewhere: offsetting the hardstand itself would just
# move the fight rather than settle it.
static var _decals := {}
static func decal(material: StandardMaterial3D, order: int = 1) -> ShaderMaterial:
	var key := "%s:%d" % [material.resource_name, order]
	if not _decals.has(key):
		var m := ShaderMaterial.new()
		m.shader = load("res://shaders/flight/decal.gdshader")
		m.set_shader_parameter("uColor", material.albedo_color)
		m.set_shader_parameter("uRoughness", material.roughness)
		m.set_shader_parameter("uMetallic", material.metallic)
		m.set_shader_parameter("uOrder", float(order))
		_decals[key] = m
	return _decals[key]

static func _node() -> Node3D:
	var n := Node3D.new()
	n.rotation_order = EULER_ORDER_XYZ
	return n

static func _mesh(g: CraftModel.Geo, m: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.rotation_order = EULER_ORDER_XYZ
	mi.mesh = CraftModel._to_mesh(g, m)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi

# ---------------------------------------------------------------------------
# A merged box soup. A lattice tower is a few thousand struts and every one of
# them as its own mesh would cost more draw calls than the rest of the sim put
# together, so they are baked into one mesh up front. Nothing in a tower moves
# relative to the rest of the tower, so there is nothing lost.
# ---------------------------------------------------------------------------
class Struts extends RefCounted:
	var g := CraftModel.Geo.new()
	var n := 0
	## A box from a→b with cross-section w×w, oriented to the segment.
	func strut(ax: float, ay: float, az: float, bx: float, by: float, bz: float, w: float) -> void:
		var d := Vector3(bx - ax, by - ay, bz - az)
		var L := d.length()
		if L < 1e-6: return
		d /= L
		var ref := Vector3(1, 0, 0) if absf(d.y) > 0.95 else Vector3(0, 1, 0)
		var u := d.cross(ref).normalized() * (w * 0.5)
		var v := d.cross(u).normalized() * (w * 0.5)
		var A := Vector3(ax, ay, az); var B := Vector3(bx, by, bz)
		var corners: Array[Vector3] = []
		for end in [A, B]:
			for sv in [[1, 1], [1, -1], [-1, -1], [-1, 1]]:
				corners.append(end + u * sv[0] + v * sv[1])
		var base := n
		for i in 8:
			g.pos.append(corners[i])
			# Flat-ish normals: a strut is thin enough that a radial normal
			# reads fine and costs no extra vertices.
			var c: Vector3 = corners[i] - (A if i < 4 else B)
			g.nrm.append(c.normalized() if c.length() > 0.0 else c)
		for f in [[0, 1, 2, 3], [7, 6, 5, 4], [0, 4, 5, 1], [1, 5, 6, 2], [2, 6, 7, 3], [3, 7, 4, 0]]:
			g.idx.append_array([base + f[0], base + f[1], base + f[2], base + f[0], base + f[2], base + f[3]])
		n += 8

## A square lattice tower: four legs, horizontal ties at `bay` intervals, and a
## pair of diagonals in every bay of every face. That is what a real umbilical
## tower is — the diagonals are what carries the wind load, and they are also
## the only reason a lattice reads as a lattice at a distance rather than as
## four lines.
static func lattice_tower(H: float, side: float, opts: Dictionary = {}) -> MeshInstance3D:
	var bay: float = opts.get("bay", 6.0)
	var leg: float = opts.get("leg", 0.55)
	var brace: float = opts.get("brace", 0.28)
	var s := Struts.new()
	var h := side / 2.0
	var legs := [[-h, -h], [h, -h], [h, h], [-h, h]]
	for l in legs: s.strut(l[0], 0.0, l[1], l[0], H, l[1], leg)
	var bays := maxi(2, int(U.jround(H / bay)))
	var dy := H / bays
	for i in bays + 1:
		var y := i * dy
		for k in 4:
			var p1: Array = legs[k]; var p2: Array = legs[(k + 1) % 4]
			s.strut(p1[0], y, p1[1], p2[0], y, p2[1], brace)
	for i in bays:
		var y0 := i * dy; var y1 := y0 + dy
		for k in 4:
			var p1: Array = legs[k]; var p2: Array = legs[(k + 1) % 4]
			# alternate the diagonal's sense per bay, as a real braced frame does
			if i % 2 == 0: s.strut(p1[0], y0, p1[1], p2[0], y1, p2[1], brace)
			else: s.strut(p2[0], y0, p2[1], p1[0], y1, p1[1], brace)
	return _mesh(s.g, STEEL())

## A horizontal truss boom — the swing arms, the catch arms, the crane jib.
static func truss(L: float, w: float, d: float, chord: float = 0.22) -> MeshInstance3D:
	var s := Struts.new()
	var hw := w / 2.0
	for z in [-hw, hw]:
		for y in [0.0, d]: s.strut(0.0, y, z, L, y, z, chord)
	var bays := maxi(2, int(U.jround(L / (d * 1.2))))
	for i in bays + 1:
		var x := (float(i) / bays) * L
		for z in [-hw, hw]: s.strut(x, 0.0, z, x, d, z, chord * 0.8)
		s.strut(x, 0.0, -hw, x, 0.0, hw, chord * 0.8)
		s.strut(x, d, -hw, x, d, hw, chord * 0.8)
	for i in bays:
		var x0 := (float(i) / bays) * L; var x1 := (float(i + 1) / bays) * L
		for z in [-hw, hw]: s.strut(x0, 0.0, z, x1, d, z, chord * 0.8)
	return _mesh(s.g, STEEL())

static func box(w: float, h: float, d: float, m: Material, x := 0.0, y := 0.0, z := 0.0) -> MeshInstance3D:
	var b := _mesh(CraftModel._box(w, h, d), m)
	b.position = Vector3(x, y + h / 2.0, z)
	return b

## THREE.RingGeometry(inner, outer, thetaSegments, 1), in XY facing +Z.
static func _ring(inner: float, outer: float, seg: int) -> CraftModel.Geo:
	var g := CraftModel.Geo.new()
	for j in 2:
		var r := inner + float(j) * (outer - inner)
		for i in seg + 1:
			var a := float(i) / seg * TAU
			g.pos.append(Vector3(r * cos(a), r * sin(a), 0.0)); g.nrm.append(Vector3(0, 0, 1))
	for i in seg:
		var a := i; var b := i + seg + 1; var c := i + seg + 2; var d := i + 1
		g.idx.append_array([a, b, d, b, c, d])
	return g

# How far the pad deck stands above the surrounding terrain. LC-39A's hardstand
# is a real mound: 390 x 325 m of octagon raised 12.8 m out of the marsh, with
# flanks sloping down to grade. That number is load-bearing for a reason that
# has nothing to do with the pad — it is the ONLY thing keeping the mound's top
# face off the ground patch. Drawn at the same height the two are exactly
# coplanar over a hundred-metre octagon, and every frame the depth test picks a
# different winner across it.
const PAD_RISE := 12.8

## The raised hardstand: an octagonal mound with sloped flanks. Its top face is
## at local y = 0 — the pad deck — and grade is PAD_RISE below that.
static func hardstand(across: float) -> MeshInstance3D:
	var m := _mesh(CraftModel._cylinder(across * 0.5, across * 0.5 + PAD_RISE * 2.6, PAD_RISE, 8, 1), CONCRETE())
	m.position.y = -PAD_RISE * 0.5   # top face at local y = 0, i.e. at the pad deck
	m.rotation.y = PI / 8.0
	return m

## THE CRAWLERWAY, which has to be a RAMP.
##
## A 1400 m road laid flat at deck height is fine for the hundred metres it
## spends on the mound and then hangs 12.8 m in the air over the plain for the
## other 1300. The real one climbs the flank — that five-percent grade is the
## steepest thing a loaded crawler-transporter is allowed to take, and it is why
## the ramp is as long as it is. Stations in (z, y) along the run, widened into
## a ribbon.
static func crawlerway(top_r: float, width: float = 40.0, len: float = 1400.0) -> MeshInstance3D:
	var toe := top_r + PAD_RISE * 2.6                 # where the flank meets grade
	var stations := [[0.0, 0.0], [-top_r, 0.0], [-toe, -PAD_RISE], [-len, -PAD_RISE]]
	var g := CraftModel.Geo.new()
	for i in stations.size():
		var z: float = stations[i][0]; var y: float = stations[i][1]
		g.pos.append(Vector3(-width / 2.0, y, z)); g.pos.append(Vector3(width / 2.0, y, z))
		g.nrm.append(Vector3.UP); g.nrm.append(Vector3.UP)
		if i > 0:
			# Wound COUNTER-CLOCKWISE SEEN FROM ABOVE (three's front face). The
			# stations run toward decreasing z, so the obvious order puts the
			# front face underneath the road and culls it from every view that
			# looks down on the pad, which is all of them.
			var b := (i - 1) * 2
			g.idx.append_array([b, b + 1, b + 2, b + 1, b + 3, b + 2])
	return _mesh(g, decal(DARKCON()))

## The flame trench and its deflector. The trench runs under the vehicle and out
## both ways; the deflector is a wedge directly beneath the engines that turns
## the exhaust through 90° and sends it out either end. Without it the plume
## reflects straight back up into the vehicle it just came out of.
static func flame_trench(len: float, wide: float, deep: float) -> Node3D:
	var g := _node()
	var wall := 2.5
	for z in [-(wide / 2.0 + wall / 2.0), wide / 2.0 + wall / 2.0]:
		g.add_child(box(len, deep, wall, DARKCON(), 0.0, -deep, z))
	g.add_child(box(len, 1.2, wide, SCORCH(), 0.0, -deep, 0.0))
	# the wedge
	var wedge := _mesh(CraftModel._cylinder(0.01, wide * 0.48, deep * 0.85, 3, 1), SCORCH())
	wedge.rotation = Vector3(0.0, PI / 2.0, 0.0)
	wedge.position.y = -deep + deep * 0.85 / 2.0
	var holder := _node()
	holder.add_child(wedge)
	holder.rotation.y = PI / 2.0
	g.add_child(holder)
	return g

## Three masts on a catenary, which is what a real lightning protection system
## is: the wire is the conductor and the masts only hold it up.
static func lightning_masts(R: float, H: float) -> Node3D:
	var g := _node()
	var tops: Array[Vector3] = []
	for i in 3:
		var a := (float(i) / 3.0) * PI * 2.0 + PI / 6.0
		var x := cos(a) * R; var z := sin(a) * R
		var m := lattice_tower(H * 0.72, 4.5, {"bay": 7.0, "leg": 0.3, "brace": 0.16})
		m.position = Vector3(x, 0.0, z)
		g.add_child(m)
		var spire := _mesh(CraftModel._cylinder(0.12, 0.5, H * 0.28, 6), STEEL())
		spire.position = Vector3(x, H * 0.72 + H * 0.14, z)
		g.add_child(spire)
		tops.append(Vector3(x, H, z))
	# catenary: y = a·cosh(x/a) — the shape a hanging cable actually takes, and
	# over this span it sags about a tenth of the run.
	var pts := PackedVector3Array()
	for i in 3:
		var A := tops[i]; var B := tops[(i + 1) % 3]
		var span := A.distance_to(B); var sag := span * 0.10
		var a := span * span / (8.0 * sag)
		for t in 17:
			var u := float(t) / 16.0; var x := (u - 0.5) * span
			var drop := a * (cosh(x / a) - cosh(span / (2.0 * a)))
			var p := A.lerp(B, u)
			p.y = A.y + drop
			pts.append(p)
	# setFromPoints draws it as one strip (THREE.Line)
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = pts
	var lm := ArrayMesh.new()
	lm.add_surface_from_arrays(Mesh.PRIMITIVE_LINE_STRIP, arr)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color.hex(0x3a3f44ff)
	var line := MeshInstance3D.new()
	line.mesh = lm
	line.material_override = mat
	g.add_child(line)
	return g

## The sound-suppression water tower. 88 m, and the tank on top holds 1.135 Ml
## — released in 41 seconds, starting before ignition.
static func water_tower(H: float = 88.0) -> Node3D:
	var g := _node()
	g.add_child(lattice_tower(H * 0.78, 9.0, {"bay": 8.0, "leg": 0.4, "brace": 0.2}))
	var tank := _mesh(CraftModel._cylinder(7.5, 7.5, H * 0.2, 20), WHITE())
	tank.position.y = H * 0.78 + H * 0.1
	g.add_child(tank)
	var cap := _mesh(CraftModel._sphere(7.5, 20, 8, 0.0, TAU, 0.0, PI / 2.0), WHITE())
	cap.position.y = H * 0.78 + H * 0.2
	g.add_child(cap)
	return g

# ---------------------------------------------------------------------------
# THE COMPLEX
# ---------------------------------------------------------------------------
const STYLES := {"saturnv": "lut", "shuttle": "fss", "falcon9": "strongback", "starship": "chopsticks"}
const STEAM_N := 340

var group: Node3D
var style: String
var deck_height: float
## How far grade — the level the ground patch is drawn at — sits below the pad
## deck: the launch mount's own height plus the hardstand's rise.
var grade_drop: float
## Height of the tallest structure, m — the camera uses it for framing. The
## same expression the tower was BUILT from, not a second guess at it.
var tower_height: float
var arms: Array = []           # [{group, axis: "yaw"|"tilt", rest, open}]
var open := 0.0
var D := 5.0
var steam: MeshInstance3D
var steam_mesh: ArrayMesh
var s_pos := PackedVector3Array()
var s_vel := PackedVector3Array()
var s_age := PackedFloat32Array()
var s_next := 0

## Build a launch complex sized to a vehicle.
##
## @param vehicle  the entry from sim/flight/vehicles.gd
## @param height   the vehicle's real stacked height, m
## @param env      Rocketry.flight_env() for the body — only its gravity
##                 matters here, and only for how far the deluge drifts
static func create_launch_site(vehicle: Dictionary, height: float, env = null) -> LaunchSite:
	return LaunchSite.new(vehicle, height, env)

func _init(vehicle: Dictionary, height: float, _env = null) -> void:
	# By `id`, not `key`. A vehicle carries `id` and has never carried `key` —
	# that belongs to its STAGES.
	style = STYLES.get(str(vehicle.get("id", "")), "lut")
	group = _node()
	group.name = "launch_site"
	D = float(vehicle.stages[0].D) if not vehicle.stages.is_empty() else 5.0

	# How high the vehicle stands above its own launch mount. The vessel's
	# altitude is measured from the planet's reference radius and reads zero on
	# the pad, so the complex is built with the DECK at group-local y = 0 and
	# everything that touches the ground sits at −deck: that puts the deck under
	# the engines rather than through them, and the grade where the ground
	# patch is drawn.
	deck_height = 23.5 if style == "chopsticks" else (9.6 if style == "strongback" else 7.6)
	var GRADE := -deck_height
	grade_drop = deck_height + PAD_RISE
	tower_height = 146.0 if style == "chopsticks" \
		else (minf(height * 0.86, 63.0) if style == "strongback"
		else (75.3 if style == "fss" else maxf(height + 12.0, 116.0)))

	# ---- ground works, common to every complex
	var ground := _node()
	ground.position.y = GRADE
	group.add_child(ground)
	var across := maxf(height * 2.6, 200.0)
	var top_r := across * 0.5
	ground.add_child(hardstand(across))
	ground.add_child(flame_trench(137.0, 18.0, 12.2))
	# The scorched apron — the single strongest cue that something violent
	# happens here. It lies ON the deck, so it is a decal: the depth bias does
	# the separating, and the 1 cm lift only keeps it clear of the trench lip.
	var apron := _mesh(CraftModel._circle(maxf(D * 5.0, 30.0), 40), decal(SCORCH(), 2))
	apron.rotation.x = -PI / 2.0
	apron.position.y = 0.01
	ground.add_child(apron)
	# The crawlerway out to the VAB — a 40 m wide river-rock road, and the only
	# thing in the scene that says which way "away" is.
	ground.add_child(crawlerway(top_r))

	# Everything that stands OFF the mound stands at grade, PAD_RISE lower.
	var plain := _node()
	plain.position.y = GRADE - PAD_RISE
	group.add_child(plain)
	# The masts stand well clear of the vehicle — they are there to intercept a
	# strike, and a conductor close enough to be in the frame is close enough
	# to be a hazard. At 39B they are about 200 m out on a 300 m catenary span.
	plain.add_child(lightning_masts(maxf(height * 2.4, top_r + 140.0), maxf(height * 1.2, 100.0)))
	var wt := water_tower(88.0)
	wt.position = Vector3(-(top_r + 60.0), 0.0, top_r * 0.8)
	plain.add_child(wt)

	# ---- the launch mount. Every part of the structure that stands on the
	# ground is built upward from zero and then dropped onto grade in one move,
	# so a change to the deck height cannot leave one piece of the tower floating.
	var mount := _node()
	mount.position.y = GRADE
	group.add_child(mount)

	if style == "lut" or style == "fss":
		# Mobile Launcher Platform: 49.4 × 41.1 m, 7.6 m deep, with a square
		# exhaust opening — four slabs around the hole, so the hole is real.
		var PW := 49.4; var PD := 41.1; var PH := 7.6; var HOLE := 13.7
		var side_w := (PW - HOLE) / 2.0; var side_d := (PD - HOLE) / 2.0
		mount.add_child(box(side_w, PH, PD, GREY(), -(HOLE / 2.0 + side_w / 2.0), 0.0, 0.0))
		mount.add_child(box(side_w, PH, PD, GREY(), +(HOLE / 2.0 + side_w / 2.0), 0.0, 0.0))
		mount.add_child(box(HOLE, PH, side_d, GREY(), 0.0, 0.0, -(HOLE / 2.0 + side_d / 2.0)))
		mount.add_child(box(HOLE, PH, side_d, GREY(), 0.0, 0.0, +(HOLE / 2.0 + side_d / 2.0)))
		# hold-down arms
		for i in 4:
			var a := (float(i) / 4.0) * PI * 2.0 + PI / 4.0
			mount.add_child(box(2.2, 3.4, 2.2, PAINT(), cos(a) * D * 0.62, PH, sin(a) * D * 0.62))
		var tower_h := maxf(height + 12.0, 116.0) if style == "lut" else 75.3
		var tower := lattice_tower(tower_h, 12.2, {"bay": 6.1})
		tower.position = Vector3(-(HOLE / 2.0 + 16.0), PH, 0.0)
		mount.add_child(tower)
		# hammerhead crane
		var jib := truss(22.0, 3.0, 3.0)
		jib.position = Vector3(-(HOLE / 2.0 + 16.0) + 6.0, PH + tower_h + 2.0, 0.0)
		mount.add_child(jib)
		mount.add_child(box(3.0, 4.0, 3.0, STEEL(), -(HOLE / 2.0 + 16.0), PH + tower_h, 0.0))
		# SWING ARMS. Nine on the LUT, at the levels where the stages actually
		# needed servicing. They carry live umbilicals, so they cannot leave
		# until the engines are running — which is why they retract ON
		# IGNITION and not before it.
		var n := 9 if style == "lut" else 5
		for i in n:
			var y := PH + 10.0 + (float(i) / (n - 1)) * (height * 0.92 - 10.0)
			var pivot := _node()
			pivot.position = Vector3(-(HOLE / 2.0 + 16.0), y, 0.0)
			var arm := truss(16.0, 2.6, 2.4)
			arm.position = Vector3(6.0, -1.2, 0.0)
			pivot.add_child(arm)
			# the white room / crew access arm is the top one and is bigger
			if i == n - 1:
				pivot.add_child(box(4.5, 4.5, 5.0, WHITE(), 16.0, -2.2, 0.0))
			mount.add_child(pivot)
			arms.append({"group": pivot, "axis": "yaw", "rest": 0.0, "open": -PI * 0.62})
		if style == "fss":
			# the Rotating Service Structure, swung clear before launch
			var rss := _node()
			rss.position = Vector3(-(HOLE / 2.0 + 16.0), PH, 0.0)
			rss.add_child(box(18.0, 40.0, 14.0, WHITE(), 14.0, 12.0, 0.0))
			mount.add_child(rss)
			arms.append({"group": rss, "axis": "yaw", "rest": -PI * 0.66, "open": -PI * 0.66})
			# vent arm and its "beanie cap" over the ET nose, drawing off the
			# boiled oxygen that would otherwise fall as ice onto the tiles
			var vent := _node()
			vent.position = Vector3(-(HOLE / 2.0 + 16.0), PH + height * 0.93, 0.0)
			var v_arm := truss(14.0, 2.2, 2.0)
			v_arm.position = Vector3(5.0, 0.0, 0.0)
			vent.add_child(v_arm)
			var cap := _mesh(CraftModel._cone(3.4, 5.0, 16, 1, true), WHITE())
			cap.position = Vector3(17.0, -1.0, 0.0)
			cap.rotation.x = PI
			vent.add_child(cap)
			mount.add_child(vent)
			arms.append({"group": vent, "axis": "yaw", "rest": 0.0, "open": -PI * 0.55})
	elif style == "strongback":
		# Falcon 9's launch mount is a small four-legged stool, and the vehicle
		# is brought out lying on the transporter-erector, which then stands it
		# up and stays alongside carrying propellant and power until it lifts.
		var leg_h := 8.0
		for i in 4:
			var a := (float(i) / 4.0) * PI * 2.0 + PI / 4.0
			mount.add_child(box(1.6, leg_h, 1.6, GREY(), cos(a) * 4.4, 0.0, sin(a) * 4.4))
		mount.add_child(box(11.0, 1.6, 11.0, GREY(), 0.0, leg_h, 0.0))
		var te := _node()
		te.position = Vector3(-(D / 2.0 + 2.6), leg_h, 0.0)
		te.add_child(lattice_tower(minf(height * 0.86, 63.0), 3.4, {"bay": 5.0, "leg": 0.3, "brace": 0.16}))
		# the two umbilical "quick disconnect" boxes that fall away at liftoff
		te.add_child(box(2.4, 3.0, 2.4, WHITE(), 1.6, height * 0.30, 0.0))
		te.add_child(box(2.4, 3.0, 2.4, WHITE(), 1.6, height * 0.62, 0.0))
		mount.add_child(te)
		# The strongback rotates about its base, away from the vehicle.
		arms.append({"group": te, "axis": "tilt", "rest": -0.035, "open": -0.30})
	else:
		# Starship: an Orbital Launch Mount on six legs with the vehicle over a
		# water-cooled steel deck, and a 146 m tower carrying two catch arms.
		var leg_h := 20.0
		for i in 6:
			var a := (float(i) / 6.0) * PI * 2.0
			mount.add_child(box(3.0, leg_h, 3.0, GREY(), cos(a) * 12.0, 0.0, sin(a) * 12.0))
		var ring := _mesh(CraftModel._cylinder(14.0, 14.0, 3.5, 24, 1, true), GREY())
		ring.position.y = leg_h + 1.75
		mount.add_child(ring)
		var deck := _mesh(_ring(6.5, 14.0, 24), SCORCH())
		deck.rotation.x = -PI / 2.0
		deck.position.y = leg_h + 3.5
		mount.add_child(deck)
		var tower := lattice_tower(146.0, 12.0, {"bay": 8.4, "leg": 0.7, "brace": 0.32})
		tower.position = Vector3(-26.0, 0.0, 0.0)
		mount.add_child(tower)
		for z in [-9.0, 9.0]:
			var pivot := _node()
			pivot.position = Vector3(-26.0, 62.0, z)
			var arm := truss(26.0, 5.0, 4.5, 0.34)
			arm.position = Vector3(6.0, 0.0, 0.0)
			pivot.add_child(arm)
			mount.add_child(pivot)
			arms.append({"group": pivot, "axis": "yaw", "rest": -0.10 if z > 0.0 else 0.10, "open": -1.15 if z > 0.0 else 1.15})

	# ---- the deluge. Points rather than geometry: it is a cloud, and a cloud
	# made of triangles is a worse cloud than a few hundred camera-facing quads.
	s_pos.resize(STEAM_N); s_vel.resize(STEAM_N); s_age.resize(STEAM_N)
	s_age.fill(-1.0)
	var sm := ShaderMaterial.new()
	sm.shader = load("res://shaders/flight/steam.gdshader")
	sm.set_shader_parameter("uSize", maxf(D * 6.0, 30.0))
	sm.render_priority = LocalView.ORDER.smoke
	steam_mesh = ArrayMesh.new()
	steam = MeshInstance3D.new()
	steam.name = "deluge"
	steam.mesh = steam_mesh
	steam.material_override = sm
	steam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	steam.custom_aabb = AABB(Vector3(-2000, -100, -2000), Vector3(4000, 2000, 4000))
	group.add_child(steam)

## @param s.released  true once the vehicle has committed to leaving
## @param s.throttle  0..1, drives the deluge
## @param s.dt        seconds
func update(s: Dictionary) -> void:
	var dt := float(s.dt)
	# Retraction state: 0 = stowed against the vehicle, 1 = fully clear. Arms
	# are heavy and hydraulic; the real ones take a couple of seconds.
	var want := 1.0 if s.released else 0.0
	open += (want - open) * (1.0 - exp(-dt / 1.6))
	for a in arms:
		var ang: float = a.rest + (a.open - a.rest) * open
		var g: Node3D = a.group
		if a.axis == "yaw": g.rotation.y = ang
		else: g.rotation.z = ang

	# deluge: on whenever the engines are, plus the pre-ignition flow
	var rate := 1.0 if float(s.throttle) > 0.0 else 0.0
	var emit := mini(int(U.jround(rate * 90.0 * dt)), STEAM_N)
	for k in emit:
		s_next = (s_next + 1) % STEAM_N
		var i := s_next
		var a := randf() * PI * 2.0
		var rr := sqrt(randf()) * D * 2.2
		s_pos[i] = Vector3(cos(a) * rr, 1.0 + randf() * 4.0, sin(a) * rr)
		# Blown out along the trench, because that is where the deflector sends
		# it, and up as it entrains air and loses momentum.
		var along := -1.0 if randf() < 0.5 else 1.0
		s_vel[i] = Vector3(along * (14.0 + randf() * 26.0), 5.0 + randf() * 12.0, (randf() - 0.5) * 8.0)
		s_age[i] = 0.0
	var pts := PackedVector3Array()
	var ages := PackedVector2Array()
	for i in STEAM_N:
		if s_age[i] < 0.0: continue
		s_age[i] += dt / 6.5
		if s_age[i] >= 1.0:
			s_age[i] = -1.0
			continue
		s_pos[i] += s_vel[i] * dt
		# buoyant, and slowing as it spreads
		var v := s_vel[i]
		v.x *= exp(-dt * 0.55)
		v.z *= exp(-dt * 0.55)
		v.y = v.y * exp(-dt * 0.3) + 3.5 * dt
		s_vel[i] = v
		pts.append(s_pos[i])
		ages.append(Vector2(s_age[i], 0.0))
	steam_mesh.clear_surfaces()
	if not pts.is_empty():
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = pts
		arr[Mesh.ARRAY_TEX_UV] = ages
		steam_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_POINTS, arr)

func dispose() -> void:
	if is_instance_valid(group): group.queue_free()
