class_name NeutronVisual
extends RefCounted

# NEUTRON STAR: ~12 km, a solar mass, a ~10⁶ K surface, a 10⁸–10¹⁵ G field.
#   · Colour: the Planck peak is soft X-ray, so the visible tail is Rayleigh–Jeans
#     blue-white (RX J1856−3754), driven well past 1.0 so the core clips white and
#     the limb keeps its colour.
#   · Self-lensing: at R ≈ 2.5 r_s,
#         cos ψ = 1 − (1 − μ)/(1 − r_s/R)
#     (μ the cosine on the apparent disc). At r_s/R = 0.4 the limb maps to ψ ≈ 132°,
#     so ~60% of the surface is visible and a polar cap stays in view longer.
#   · Hot magnetic polar caps, the source of the pulse.
#   · A misaligned dipole, so caps and beams sweep; relativistic beaming sharpens
#     the pulse into a spike.
#   · Dipole field lines r = r₀·sin²θ as glowing tubes.
#   · Hollow radio/X-ray beams: emission from the cone wall near the last open field
#     lines.
# Camera-relative throughout. Shaders: neutron_surface, neutron_beam, neutron_field.

const SURF_SHADER := preload("res://shaders/bodies/neutron_surface.gdshader")
const BEAM_SHADER := preload("res://shaders/bodies/neutron_beam.gdshader")
const FIELD_SHADER := preload("res://shaders/bodies/neutron_field.gdshader")

# THREE.CatmullRomCurve3 (centripetal) and TubeGeometry, reproduced: arc-length
# sampling over 200 divisions, parallel-transported frame, CCW index order (see
# neutron_field.gdshader's cull note).
static func _cubic(x0: float, x1: float, x2: float, x3: float, dt0: float, dt1: float, dt2: float, t: float) -> float:
	# initNonuniformCatmullRom, then init() and calc()
	var t1 := (x1 - x0) / dt0 - (x2 - x0) / (dt0 + dt1) + (x2 - x1) / dt1
	var t2 := (x2 - x1) / dt1 - (x3 - x1) / (dt1 + dt2) + (x3 - x2) / dt2
	t1 *= dt1; t2 *= dt1
	var c0 := x1; var c1 := t1
	var c2 := -3.0 * x1 + 3.0 * x2 - 2.0 * t1 - t2
	var c3 := 2.0 * x1 - 2.0 * x2 + t1 + t2
	return c0 + c1 * t + c2 * t * t + c3 * t * t * t

static func _catmull(pts: Array, t: float) -> Vector3:
	var l := pts.size()
	var p := (l - 1) * t
	var ip := int(floor(p))
	var w := p - ip
	if w == 0.0 and ip == l - 1:
		ip = l - 2; w = 1.0
	var p1: Vector3 = pts[ip]
	var p2: Vector3 = pts[ip + 1]
	var p0: Vector3 = pts[ip - 1] if ip > 0 else (pts[0] - pts[1]) + pts[0]
	var p3: Vector3 = pts[ip + 2] if ip + 2 < l else (pts[l - 1] - pts[l - 2]) + pts[l - 1]
	var dt0 := pow(p0.distance_squared_to(p1), 0.25)
	var dt1 := pow(p1.distance_squared_to(p2), 0.25)
	var dt2 := pow(p2.distance_squared_to(p3), 0.25)
	if dt1 < 1e-4: dt1 = 1.0
	if dt0 < 1e-4: dt0 = dt1
	if dt2 < 1e-4: dt2 = dt1
	return Vector3(_cubic(p0.x, p1.x, p2.x, p3.x, dt0, dt1, dt2, w),
		_cubic(p0.y, p1.y, p2.y, p3.y, dt0, dt1, dt2, w),
		_cubic(p0.z, p1.z, p2.z, p3.z, dt0, dt1, dt2, w))

static func _tube(pts: Array, tubular: int, radius: float, radial: int) -> ArrayMesh:
	# arc-length table (Curve.getLengths(200))
	var div := 200
	var lengths := PackedFloat64Array([0.0])
	var last := _catmull(pts, 0.0)
	for i in range(1, div + 1):
		var c := _catmull(pts, float(i) / div)
		lengths.append(lengths[i - 1] + c.distance_to(last))
		last = c
	var total := lengths[div]
	var u_to_t := func(u: float) -> float:
		var target := u * total
		var lo := 0; var hi := div
		while lo <= hi:
			var mid := lo + (hi - lo) / 2
			var cmp := lengths[mid] - target
			if cmp < 0.0: lo = mid + 1
			elif cmp > 0.0: hi = mid - 1
			else: hi = mid; break
		var i := hi
		if i < 0: i = 0
		if lengths[i] == target or i >= div: return float(i) / div
		var seg := lengths[i + 1] - lengths[i]
		return (float(i) + (target - lengths[i]) / seg) / div
	var P := []
	var T := []
	for i in tubular + 1:
		var t: float = u_to_t.call(float(i) / tubular)
		P.append(_catmull(pts, t))
		var t1 := clampf(t - 1e-4, 0.0, 1.0); var t2 := clampf(t + 1e-4, 0.0, 1.0)
		T.append((_catmull(pts, t2) - _catmull(pts, t1)).normalized())
	# frames: initial normal perpendicular to the tangent's smallest component,
	# then parallel transport (computeFrenetFrames)
	var t0: Vector3 = T[0]
	var ax := Vector3(1, 0, 0)
	var mn := absf(t0.x)
	if absf(t0.y) <= mn: mn = absf(t0.y); ax = Vector3(0, 1, 0)
	if absf(t0.z) <= mn: ax = Vector3(0, 0, 1)
	var vec := t0.cross(ax).normalized()
	var N := [t0.cross(vec)]
	var B := [t0.cross(N[0])]
	for i in range(1, tubular + 1):
		var n: Vector3 = N[i - 1]
		var v := (T[i - 1] as Vector3).cross(T[i])
		if v.length() > 1e-8:
			v = v.normalized()
			var th := acos(clampf((T[i - 1] as Vector3).dot(T[i]), -1.0, 1.0))
			n = n.rotated(v, th)
		N.append(n)
		B.append((T[i] as Vector3).cross(n))
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	for i in tubular + 1:
		for j in radial + 1:
			var a := float(j) / radial * TAU
			var nn: Vector3 = (-cos(a)) * N[i] + sin(a) * B[i]
			nn = nn.normalized()
			norms.append(nn)
			verts.append(P[i] + nn * radius)
	var idx := PackedInt32Array()
	for j in range(1, tubular + 1):
		for i in range(1, radial + 1):
			var a := (radial + 1) * (j - 1) + (i - 1)
			var b := (radial + 1) * j + (i - 1)
			var c := (radial + 1) * j + i
			var d := (radial + 1) * (j - 1) + i
			idx.append_array([a, b, d, b, c, d])
	var arr := []; arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return m

# A closed dipole field line: r = r0·sin²θ, swept from one pole to the other.
static func field_line_geometry(R: float, r0: float, segments: int = 48) -> ArrayMesh:
	var pts := []
	for i in segments + 1:
		var th := (float(i) / segments) * PI
		var s := sin(th)
		var r := r0 * s * s
		if r < R * 0.98: continue                 # clip where it enters the crust
		pts.append(Vector3(r * s, r * cos(th), 0.0))
	if pts.size() < 2: return null
	return _tube(pts, 40, R * 0.010, 5)

# THREE.ConeGeometry(open, len, 40, 24, openEnded), shifted and flipped: apex at the
# star, mouth at +len. Positions only.
static func _beam_cone(open: float, length: float, radial: int = 40, rows: int = 24) -> ArrayMesh:
	var verts := PackedVector3Array()
	for iy in rows + 1:
		var v := float(iy) / rows
		var rad := v * open
		for ix in radial + 1:
			var th := float(ix) / radial * TAU
			verts.append(Vector3(rad * sin(th), v * length, rad * cos(th)))
	var idx := PackedInt32Array()
	for iy in rows:
		for ix in radial:
			var a := iy * (radial + 1) + ix
			var b := (iy + 1) * (radial + 1) + ix
			var c := (iy + 1) * (radial + 1) + ix + 1
			var d := iy * (radial + 1) + ix + 1
			idx.append_array([a, b, d, b, c, d])
	var arr := []; arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return m

static func create_neutron_visual(b: Body, opts: VisualOpts) -> NeutronViz:
	var viz := NeutronViz.new(b, opts)
	b.viz = viz
	return viz

class NeutronViz:
	extends RefCounted
	var body: Body
	var group: Node3D
	var core: MeshInstance3D
	var spin_axis: Node3D
	var mag_axis: Node3D
	var base_r: float
	var r: float
	var is_neutron := true
	var is_star := false
	var is_hole := false
	var stream = null               # AccretionStream, attached by sim/bodies.gd
	var surf_mat: ShaderMaterial
	var field_mat: ShaderMaterial
	var beams: Array = []           # the two beam ShaderMaterials
	var time := 0.0                 # surface uTime
	var beam_time := 0.0

	func _init(b: Body, opts: VisualOpts) -> void:
		body = b
		group = Node3D.new()
		var R: float = opts.radius_scene

		# r_s/R for a real neutron star: r_s ≈ 4.1 km per M☉, R ≈ 12 km ⇒ ~0.4 at
		# 1.4 M☉. Taken from the body's own numbers when they exist.
		var compact := clampf(b.rs / b.radius if (b.rs > 0.0 and b.radius > 0.0) else 0.4, 0.15, 0.65)

		# ~10⁶ K: we are on the Rayleigh–Jeans tail, so a hard blue-white.
		# (THREE.Color from floats: linear, not colour-managed.)
		var surf_color := Color(0.30, 0.52, 1.0)
		var cap_color := Color(0.80, 0.90, 1.0)
		var mag_color := Color(0.45, 0.72, 1.0)

		surf_mat = ShaderMaterial.new()
		surf_mat.shader = NeutronVisual.SURF_SHADER
		# Gain: caps and lensed rim clip white, the crust keeps its blue-white.
		surf_mat.set_shader_parameter("uGain", 1.35)
		surf_mat.set_shader_parameter("uCompact", compact)
		surf_mat.set_shader_parameter("uCapGlow", 0.0)
		surf_mat.set_shader_parameter("uTeffK", 1.0e6)     # typical young neutron-star surface
		surf_mat.set_shader_parameter("uColor", Vector3(surf_color.r, surf_color.g, surf_color.b))
		surf_mat.set_shader_parameter("uCapColor", Vector3(cap_color.r, cap_color.g, cap_color.b))
		surf_mat.set_shader_parameter("uMagAxis", Vector3(sin(0.55), cos(0.55), 0.0).normalized())
		core = MeshInstance3D.new()
		core.name = "Crust"
		var sph := SphereMesh.new()
		sph.radius = R; sph.height = 2.0 * R; sph.radial_segments = 48; sph.rings = 36
		core.mesh = sph
		core.material_override = surf_mat
		core.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		group.add_child(core)

		# --- spin axis → tilted magnetic axis (the misaligned dipole)
		spin_axis = Node3D.new()
		group.add_child(spin_axis)
		mag_axis = Node3D.new()
		mag_axis.rotation.z = 0.55
		spin_axis.add_child(mag_axis)

		# --- closed magnetosphere: dipole field lines around the magnetic axis
		field_mat = ShaderMaterial.new()
		field_mat.shader = NeutronVisual.FIELD_SHADER
		field_mat.set_shader_parameter("uColor", Vector3(mag_color.r, mag_color.g, mag_color.b))
		field_mat.set_shader_parameter("uAlpha", 0.6)
		field_mat.set_shader_parameter("uR", R)
		var field_lines := Node3D.new()
		for shell in 3:
			var r0 := R * (2.6 + shell * 2.1)
			var geo := NeutronVisual.field_line_geometry(R, r0)
			if geo == null: continue
			for i in 5:
				var line := MeshInstance3D.new()
				line.mesh = geo
				line.material_override = field_mat
				line.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				line.rotation.y = (float(i) / 5.0) * TAU + shell * 0.4
				field_lines.add_child(line)
		mag_axis.add_child(field_lines)

		# --- the two beams
		var beam_len := R * 16.0
		var beam_open := beam_len * 0.30
		var cone_geo := NeutronVisual._beam_cone(beam_open, beam_len)
		for s in [1, -1]:
			var m := ShaderMaterial.new()
			m.shader = NeutronVisual.BEAM_SHADER
			m.set_shader_parameter("uColor", Vector3(mag_color.r, mag_color.g, mag_color.b))
			m.set_shader_parameter("uAlpha", 0.45)
			m.set_shader_parameter("uOpen", beam_open)
			m.set_shader_parameter("uLength", beam_len)
			var cone := MeshInstance3D.new()
			cone.mesh = cone_geo
			cone.material_override = m
			cone.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			# the cone opens along +Y from the star; the second one points the
			# other way down the magnetic axis
			cone.rotation.x = 0.0 if s > 0 else PI
			mag_axis.add_child(cone)
			beams.append(m)

		if b.visual_spin_rad_s == null:
			if b.default_visual_spin_rad_s == null:
				b.default_visual_spin_rad_s = 8.0 + randf() * 20.0
			b.visual_spin_rad_s = b.default_visual_spin_rad_s

		base_r = R
		r = R

	func update(dt: float, ctx: VisualCtx) -> void:
		time += dt
		surf_mat.set_shader_parameter("uTime", time)
		body.spin_phase = fmod(body.spin_phase + float(body.visual_spin_rad_s) * dt, TAU)
		spin_axis.rotation.y = body.spin_phase

		# Keep the shader's cap axis on the rotating dipole, in object space (spin × tilt).
		var local_dir := (spin_axis.basis * mag_axis.basis * Vector3.UP).normalized()
		surf_mat.set_shader_parameter("uMagAxis", local_dir)
		var gb := group.global_basis.orthonormalized() if group.is_inside_tree() else group.basis.orthonormalized()
		var beam_dir := (gb * local_dir).normalized()

		# --- the lighthouse: beaming makes the pulse a sharp spike.
		var wp := group.global_position if group.is_inside_tree() else group.position
		var cam_p := Vector3.ZERO
		var cam := ctx.camera
		if cam != null and cam.is_inside_tree():
			cam_p = cam.global_position
		var to_cam := (cam_p - wp).normalized()
		var align := absf(beam_dir.dot(to_cam))
		var flash := pow(align, 14.0)

		surf_mat.set_shader_parameter("uCapGlow", flash)
		beam_time += dt
		for m in beams:
			m.set_shader_parameter("uTime", beam_time)
			m.set_shader_parameter("uAlpha", 0.35 + flash * 1.5)
		field_mat.set_shader_parameter("uAlpha", 0.5 + flash * 0.9)

		if stream != null:
			Bodies.update_accretion_stream(body, ctx, stream, dt)
