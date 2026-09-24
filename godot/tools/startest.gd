extends Harness
# ============================================================================
# STAR / COMPACT-OBJECT HARNESS — rebuilds a frame of the web build from the
# state it was drawn from (tools/stars_dump.js, via webref.mjs `dump`) and
# renders it through the real pipeline:
#
#   Godot --path godot res://tools/startest.tscn -- state=/abs/x.json out=/abs/x.png frames=8
#
# The dump carries the camera (absolute position + quaternion + fov), every
# body's attachVisual opts, the live ActivityModel (regions, flares, CMEs),
# every shader clock, the markers, the flash sprites and the spacetime slab.
# Visual updates then run with dt = 0 and sim_dt = 0, so every clock stays at
# the dumped value and the frame is the web's frame. Numeric cross-checks
# (uniforms the port derives itself vs. the web's) are printed as CHECK lines.
# ============================================================================

var d: Dictionary
var bodies: Array = []           # Body
var markers: Array = []          # [Body, Marker, dump]
var flashes: Array = []          # Flash
var slab: SpacetimeMesh = null
var viewport_h := 720.0

static func _col(a) -> Variant:
	return Color(a[0], a[1], a[2]) if a != null else null

func _check(label: String, godot_v, web_v) -> void:
	var ok := true
	if godot_v is float or godot_v is int:
		ok = absf(float(godot_v) - float(web_v)) <= 1e-4 * maxf(1.0, absf(float(web_v)))
	print("CHECK %s %s godot=%s web=%s" % ["ok  " if ok else "DIFF", label, str(godot_v), str(web_v)])

func _setup() -> void:
	var f := FileAccess.open(str(args.get("state", "")), FileAccess.READ)
	d = JSON.parse_string(f.get_as_text())
	viewport_h = float(d.viewport[1])
	pipe.set_view_size(Vector2i(int(d.viewport[0]), int(d.viewport[1])))
	pipe.set_band(int(d.band))
	pipe.postfx.set_scene_temp(float(d.sceneMaxT) if d.sceneMaxT > 0 else 5800.0)
	var c: Dictionary = d.cam
	pipe.scene_cam.fov = float(c.fov)
	pipe.scene_cam.near = float(c.near)
	# THREE drew with near 8e-7 and far 1e5 (a ratio of 1e11) and was fine;
	# Godot is not — its frustum planes are derived in float32 from the
	# projection and at that ratio they degenerate ("create_frustum_points"
	# errors) and the culler throws the body away. Keep the ratio at 1e7,
	# which is ample for every scene here. (Reported for the orchestrator's
	# near-plane policy.)
	pipe.scene_cam.far = minf(float(c.far), float(c.near) * float(args.get("farratio", "1e7")))
	cam_pos = DVec3.from_array(c.pos)

	for e in d.bodies:
		var b := Body.new()
		b.id = int(e.id); b.name = e.name; b.type = e.type
		b.mass = float(e.mass); b.mass0 = float(U.nz(e.mass0, e.mass))
		b.radius = float(U.nz(e.radius, 0.0)); b.rs = float(U.nz(e.rs, 0.0))
		b.teff = e.teff; b.spin_frac = float(U.nz(e.spinFrac, 0.0)); b.radius_sun = e.radiusSun
		b.spin = e.spin
		b.radius_scene = float(e.radiusScene); b.rs_scene = float(U.nz(e.rsScene, 0.0))
		b.scene_pos = DVec3.from_array(e.pos)
		bodies.append(b)
		if e.type in ["star", "white-dwarf", "neutron", "bh", "star-basic"]:
			var o: Dictionary = e.opts.duplicate()
			o.color = _col(o.get("color"))
			if o.get("glow") != null: o.glow = int(o.glow)
			var viz = Bodies.create_body_visual(b, o)
			viz.group.scale = Vector3(e.scale[0], e.scale[1], e.scale[2])
			viz.group.set_meta("base_scale", float(e.scale[0]))
			pipe.world_root.add_child(viz.group)
			place(viz.group, b.scene_pos)
			if e.has("u"): _inject_star(b, viz, e)
			if e.has("neutron"): _inject_neutron(b, viz, e)
		if e.has("marker"):
			var m := Marker.create_marker({"color": _col(e.marker.color), "teff": float(U.nz(e.teff, 0.0)), "gain": float(e.marker.gain)})
			pipe.world_root.add_child(m.mesh)
			markers.append([b, m, e.marker])

	# the flash sprites a core collapse spawns (blackhole_sim.js coreCollapse),
	# stepped through the same frames the web ran after it
	if d.pre != null:
		var size := maxf(float(d.pre.radiusScene) * 22.0, 1.5)
		var at := DVec3.from_array(d.pre.pos)
		var made := [Flash.create(0xffffff, size, 0.55), Flash.create(0xffd0a0, size * 0.6, 0.16, 12.0, "shell")]
		for i in made.size():
			var fl: Flash = made[i]
			# The flashes run on the page's wall clock, which headless Chrome
			# keeps ticking between SIM.frame() calls — so the number of frames
			# they lived is not known, but their opacity is. Recover the life
			# from it (opacity = life for light; life^1.5 / (1 + grow·√(1−life))
			# for a shell, monotonic, by bisection) and let step() derive the
			# rest: the scale is then an independent check.
			var target: float = d.sprites[i].opacity if i < d.sprites.size() else 0.5
			var lo := 0.0; var hi := 1.0
			for it in 60:
				var mid := (lo + hi) * 0.5
				var op := pow(mid, 1.5) / (1.0 + fl.grow * sqrt(1.0 - mid)) if fl.shell else mid
				if op < target: lo = mid
				else: hi = mid
			fl.life = (lo + hi) * 0.5
			fl.step(0.0)
			pipe.world_root.add_child(fl.node)
			place(fl.node, at)
			flashes.append(fl)
		for i in flashes.size():
			if i < d.sprites.size():
				_check("flash%d.scale" % i, flashes[i].node.scale.x, d.sprites[i].scale)
				_check("flash%d.opacity" % i, flashes[i].mat.get_shader_parameter("uOpacity"), d.sprites[i].opacity)

	if d.mesh != null and d.mesh.visible:
		slab = SpacetimeMesh.new()
		pipe.world_root.add_child(slab.node)

func _inject_star(b: Body, viz, e: Dictionary) -> void:
	var u: Dictionary = e.u
	for k in ["uGranScale", "uGain", "uOmega", "uLimbU", "uTpole", "uSpin", "uGdBeta", "uTeff"]:
		_check("%s.%s" % [b.name, k], float(viz.mat.get_shader_parameter(k)), u[k])
	for k in ["uColPole", "uColEq", "uHot"]:
		var g: Vector3 = viz.mat.get_shader_parameter(k)
		_check("%s.%s" % [b.name, k], "%.4f,%.4f,%.4f" % [g.x, g.y, g.z], "%.4f,%.4f,%.4f" % u[k])
	viz.time = float(u.uTime)
	viz.corona_time = float(e.coronaTime)
	for i in viz.erupt.size():
		viz.erupt[i].rope.time = float(e.arcTimes[i][0])
		viz.erupt[i].arcade.time = float(e.arcTimes[i][1])
	for i in viz.cmes.size():
		viz.cmes[i].seed = float(e.cmeSlots[i].seed)
		viz.cmes[i].time = float(e.cmeSlots[i].time)
	var a: Stellar.ActivityModel = b.activity
	var A: Dictionary = e.activity
	a.regions = []
	for r in A.regions: a.regions.append(r.duplicate())
	a.flares = []
	for fl in A.flares:
		var g: Dictionary = fl.duplicate()
		g.region = fl.region.duplicate()
		g.dir = Vector3(fl.dir[0], fl.dir[1], fl.dir[2])
		a.flares.append(g)
	a.cmes = []
	for cm in A.cmes:
		var g: Dictionary = cm.duplicate()
		g.dir = Vector3(cm.dir[0], cm.dir[1], cm.dir[2])
		a.cmes.append(g)
	a.flux = float(A.flux)
	a.next = float(A.next) if A.next != null else INF

func _inject_neutron(b: Body, viz, e: Dictionary) -> void:
	viz.spin_axis.rotation.y = float(e.neutron.spinY)
	viz.time = float(e.neutron.time)
	viz.beam_time = float(e.neutron.beamTime)

func update_camera() -> void:
	var q: Array = d.cam.quat
	pipe.scene_cam.transform = Transform3D(Basis(Quaternion(q[0], q[1], q[2], q[3])), Vector3.ZERO)

var _checked := false
func _step(_dt: float) -> void:
	var ctx := {
		"holes": [], "camera": pipe.scene_cam, "cam_pos": cam_pos, "time": float(d.time),
		"scene_scale": float(d.sceneScale), "sim_dt": 0.0, "viewport_h": viewport_h, "bodies": bodies,
	}
	for b in bodies:
		if b.viz != null:
			b.viz.update(0.0, ctx)
	for mk in markers:
		var b: Body = mk[0]
		var m: Marker = mk[1]
		var op := m.update(pipe.scene_cam, b.scene_pos.rel_v3(cam_pos), maxf(b.radius_scene, b.rs_scene),
			viewport_h, b.id == int(U.nz(d.focusId, -1)))
		if not _checked:
			_check("%s.marker.opacity" % b.name, op, mk[2].opacity)
			if op > 0.002: _check("%s.marker.scale" % b.name, m.mesh.scale.x, mk[2].scale)
	if slab != null:
		slab.update(bodies, float(d.mesh.pos[0]), float(d.mesh.pos[2]), 0.0, cam_pos)
		if not _checked:
			_check("mesh.wellCount", slab.mat.get_shader_parameter("wellCount"), d.mesh.wellCount)
			var w: PackedVector4Array = slab.mat.get_shader_parameter("wells")
			for i in int(d.mesh.wellCount):
				_check("mesh.well%d" % i, "%.4f,%.4f,%.4f,%.0f" % [w[i].x, w[i].y, w[i].z, w[i].w], "%.4f,%.4f,%.4f,%.0f" % d.mesh.wells[i])
	if not _checked:
		for b in bodies:
			if b.viz != null and b.viz.get("is_star") and b.viz.get("core") != null:
				for e in d.bodies:
					if int(e.id) == b.id and e.has("coreScale"):
						_check("%s.coreScale" % b.name, b.viz.core.scale.x, e.coreScale)
						_check("%s.uFlareCount" % b.name, b.viz.mat.get_shader_parameter("uFlareCount"), e.u.uFlareCount)
						_check("%s.uSpotCount" % b.name, b.viz.mat.get_shader_parameter("uSpotCount"), e.u.uSpotCount)
						_check("%s.coronaFlux" % b.name, b.viz.corona_mat.get_shader_parameter("uFlux"), e.coronaFlux)
	_checked = true
